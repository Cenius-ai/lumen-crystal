require "kemal"
require "sqlite3"
require "json"
require "crypto/bcrypt"
require "base64"
require "ecr"
require "uri"

# ── Route manifest ──────────────────────────────────────────
# GET  /                    Homepage: link listing, sortable, filterable by tag
# GET  /tag/:name           Tag browse page, sortable
# GET  /link/:id            Link detail with threaded comments
# GET  /submit              Link submission form (auth required)
# POST /link                Create new link (auth required)
# POST /vote                Upvote/downvote toggle (auth required, JSON)
# POST /comment             Create comment/reply (auth required)
# GET  /login               Login form
# POST /login               Authenticate user
# GET  /register            Registration form
# POST /register            Create account
# GET  /logout              Destroy session
# GET  /search?q=&sort=     Full-text search across titles, bodies, tags
# GET  /user/:username      User profile: submitted links, recent comments
# GET  /health              Health check

PORT = (ENV["PORT"]? || "3000").to_i
HOST_BINDING = "0.0.0.0"
DB_PATH = ENV["DATABASE_URL"]? || "./lumen.db"

APP_DB = DB.open "sqlite3:#{DB_PATH}"

def create_schema
  APP_DB.exec <<-SQL
    CREATE TABLE IF NOT EXISTS users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      username TEXT NOT NULL UNIQUE,
      email TEXT NOT NULL UNIQUE,
      password_hash TEXT NOT NULL,
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    )
  SQL
  APP_DB.exec <<-SQL
    CREATE TABLE IF NOT EXISTS links (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL,
      url TEXT NOT NULL,
      body TEXT DEFAULT '',
      user_id INTEGER NOT NULL REFERENCES users(id),
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    )
  SQL
  APP_DB.exec <<-SQL
    CREATE TABLE IF NOT EXISTS tags (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL UNIQUE
    )
  SQL
  APP_DB.exec <<-SQL
    CREATE TABLE IF NOT EXISTS link_tags (
      link_id INTEGER NOT NULL REFERENCES links(id),
      tag_id INTEGER NOT NULL REFERENCES tags(id),
      PRIMARY KEY (link_id, tag_id)
    )
  SQL
  APP_DB.exec <<-SQL
    CREATE TABLE IF NOT EXISTS votes (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      link_id INTEGER NOT NULL REFERENCES links(id),
      user_id INTEGER NOT NULL REFERENCES users(id),
      direction TEXT NOT NULL CHECK(direction IN ('up', 'down')),
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      UNIQUE(link_id, user_id)
    )
  SQL
  APP_DB.exec <<-SQL
    CREATE TABLE IF NOT EXISTS comments (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      body TEXT NOT NULL,
      user_id INTEGER NOT NULL REFERENCES users(id),
      link_id INTEGER NOT NULL REFERENCES links(id),
      parent_id INTEGER REFERENCES comments(id),
      created_at TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at TEXT NOT NULL DEFAULT (datetime('now'))
    )
  SQL
  APP_DB.exec "CREATE INDEX IF NOT EXISTS idx_links_user ON links(user_id)"
  APP_DB.exec "CREATE INDEX IF NOT EXISTS idx_links_created ON links(created_at)"
  APP_DB.exec "CREATE INDEX IF NOT EXISTS idx_votes_link ON votes(link_id)"
  APP_DB.exec "CREATE INDEX IF NOT EXISTS idx_votes_user ON votes(user_id)"
  APP_DB.exec "CREATE INDEX IF NOT EXISTS idx_comments_link ON comments(link_id)"
  APP_DB.exec "CREATE INDEX IF NOT EXISTS idx_comments_user ON comments(user_id)"
  APP_DB.exec "CREATE INDEX IF NOT EXISTS idx_comments_parent ON comments(parent_id)"
  APP_DB.exec "CREATE INDEX IF NOT EXISTS idx_link_tags_link ON link_tags(link_id)"
  APP_DB.exec "CREATE INDEX IF NOT EXISTS idx_link_tags_tag ON link_tags(tag_id)"
end

SESSION_SECRET = ENV["SESSION_SECRET"]? || "lumen-dev-3f7a1b09e5c24d8a"

def session_token(env) : String?
  env.request.cookies["lumen_session"]?.try(&.value)
end

def current_user_id(env) : Int64?
  token = session_token(env)
  return nil unless token
  begin
    payload = Base64.decode_string(token)
    user_id, _ = payload.split("|", 2)
    user_id.to_i64?
  rescue
    nil
  end
end

def current_user(env)
  uid = current_user_id(env)
  return nil unless uid
  APP_DB.query_one?("SELECT id, username, email, created_at FROM users WHERE id = ?", uid,
    as: {id: Int64, username: String, email: String, created_at: String})
end

def set_session(env, user_id : Int64)
  payload = "#{user_id}|#{Time.utc.to_unix}"
  token = Base64.strict_encode(payload)
  env.response.cookies["lumen_session"] = HTTP::Cookie.new(
    name: "lumen_session", value: token, path: "/",
    http_only: true, samesite: HTTP::Cookie::SameSite::Lax, max_age: Time::Span.new(days: 30, hours: 0, minutes: 0, seconds: 0)
  )
end

def clear_session(env)
  env.response.cookies["lumen_session"] = HTTP::Cookie.new(
    name: "lumen_session", value: "", path: "/", http_only: true, max_age: Time::Span.new(seconds: 0)
  )
end

def esc(text : String) : String
  HTML.escape(text)
end

def time_ago(ts : String) : String
  begin
    t = Time.parse(ts, "%Y-%m-%d %H:%M:%S", Time::Location::UTC)
    diff = Time.utc - t
    if diff.total_seconds < 60; "just now"
    elsif diff.total_minutes < 60; "#{diff.total_minutes.to_i}m ago"
    elsif diff.total_hours < 24; "#{diff.total_hours.to_i}h ago"
    elsif diff.total_days < 30; "#{diff.total_days.to_i}d ago"
    elsif diff.total_days < 365; "#{(diff.total_days/30).to_i}mo ago"
    else "#{(diff.total_days/365).to_i}y ago"
    end
  rescue; ts
  end
end

def link_vote_count(link_id : Int64) : Int64
  up = APP_DB.scalar("SELECT COUNT(*) FROM votes WHERE link_id = ? AND direction = 'up'", link_id).as(Int64)
  down = APP_DB.scalar("SELECT COUNT(*) FROM votes WHERE link_id = ? AND direction = 'down'", link_id).as(Int64)
  up - down
end

def user_vote_dir(link_id : Int64, user_id : Int64?) : String?
  return nil unless user_id
  APP_DB.query_one?("SELECT direction FROM votes WHERE link_id = ? AND user_id = ?", link_id, user_id, as: String)
end

def link_tags_for(link_id : Int64)
  APP_DB.query_all("SELECT t.id, t.name FROM tags t INNER JOIN link_tags lt ON t.id = lt.tag_id WHERE lt.link_id = ? ORDER BY t.name", link_id,
    as: {id: Int64, name: String})
end

def top_tags(limit = 20)
  APP_DB.query_all("SELECT t.id, t.name, COUNT(lt.link_id) as cnt FROM tags t INNER JOIN link_tags lt ON t.id = lt.tag_id GROUP BY t.id ORDER BY cnt DESC, t.name ASC LIMIT ?", limit,
    as: {id: Int64, name: String, cnt: Int64})
end

def extract_domain(url_str : String) : String
  begin
    uri = URI.parse(url_str)
    uri.host.to_s.sub(/^www\./, "")
  rescue; url_str
  end
end

def require_auth(env)
  uid = current_user_id(env)
  unless uid
    env.response.status_code = 302
    env.response.headers["Location"] = "/login"
    return nil
  end
  uid
end

# ── HTML builders ──────────────────────────────────────────

def build_layout(env, page_title : String, body_html : String) : String
  user = current_user(env)
  ttags = top_tags
  String.build do |s|
    s << %(<!DOCTYPE html><html lang="en" data-theme="light"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>#{page_title} — Lumen</title>)
    s << %(<style>@media(max-width:768px){.app-shell{flex-direction:column}.sidebar{width:100%%;min-width:100%%;height:auto;position:relative;flex-wrap:wrap;padding:var(--s-3);gap:var(--s-2)}.sidebar-nav{flex-direction:row;flex-wrap:wrap}.sidebar-tags{display:none}.link-list,.form-container,.page-header,.search-form-page,.profile-page,.link-detail{padding-left:var(--s-4);padding-right:var(--s-4)}.link-card{gap:var(--s-3)}.page-title{font-size:var(--text-2xl)}.comment-reply{margin-left:var(--s-3)}}@media(max-width:480px){.link-card{flex-direction:column}.link-vote{flex-direction:row;gap:var(--s-2);min-width:auto}.sort-tabs{width:100%%}.sort-tab{flex:1;text-align:center}.link-footer{flex-direction:column;align-items:flex-start}}</style>)
    s << %(<link rel="stylesheet" href="/css/style.css"></head><body><div class="app-shell">)
    s << %(<aside class="sidebar"><div class="sidebar-header"><a href="/" class="logo"><span class="logo-icon">&#9670;</span><span class="logo-text">Lumen</span></a></div>)
    s << %(<nav class="sidebar-nav"><a href="/" class="nav-item">Home</a><a href="/search" class="nav-item">Search</a>)
    if user; s << %(<a href="/submit" class="nav-item">Submit</a>); end
    s << %(</nav><div class="sidebar-tags"><h3 class="sidebar-section-title">Popular Tags</h3><div class="tag-list-sidebar">)
    ttags.each do |tag|
      s << %(<a href="/tag/#{esc(tag[:name])}" class="tag-pill-sidebar">#{esc(tag[:name])} <span class="tag-count">#{tag[:cnt]}</span></a>)
    end
    s << %(</div></div><div class="sidebar-footer">)
    if user
      s << %(<div class="user-info-mini"><a href="/user/#{esc(user[:username])}" class="user-link">#{esc(user[:username])}</a></div>)
      s << %(<a href="/logout" class="btn btn-ghost btn-sm">Log out</a>)
    else
      s << %(<a href="/login" class="btn btn-ghost btn-sm">Log in</a><a href="/register" class="btn btn-primary btn-sm">Sign up</a>)
    end
    s << %(</div></aside><main class="main-content"><div class="top-bar"><div class="top-bar-left">)
    s << %(<button class="theme-toggle" id="themeToggle" aria-label="Toggle theme"><svg class="icon-sun" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="5"></circle><line x1="12" y1="1" x2="12" y2="3"></line><line x1="12" y1="21" x2="12" y2="23"></line><line x1="4.22" y1="4.22" x2="5.64" y2="5.64"></line><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"></line><line x1="1" y1="12" x2="3" y2="12"></line><line x1="21" y1="12" x2="23" y2="12"></line><line x1="4.22" y1="19.78" x2="5.64" y2="18.36"></line><line x1="18.36" y1="5.64" x2="19.78" y2="4.22"></line></svg>)
    s << %(<svg class="icon-moon" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 12.79A9 9 0 1111.21 3 7 7 0 0021 12.79z"></path></svg></button></div>)
    if user; s << %(<span class="top-bar-greeting">Welcome, <a href="/user/#{esc(user[:username])}">#{esc(user[:username])}</a></span>); end
    s << %(</div>#{body_html}</main></div><script src="/js/theme.js"></script></body></html>)
  end
end

def build_link_card(link) : String
  tags = link_tags_for(link[:id])
  domain = extract_domain(link[:url])
  String.build do |s|
    s << %(<article class="link-card"><div class="link-vote"><span class="vote-count">#{link[:vote_count]}</span><span class="vote-label">votes</span></div><div class="link-body">)
    s << %(<div class="link-meta-row"><span class="link-domain">#{esc(domain)}</span><span class="link-comment-count"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 15a2 2 0 01-2 2H7l-4 4V5a2 2 0 012-2h14a2 2 0 012 2z"></path></svg> #{link[:comment_count]}</span></div>)
    s << %(<h2 class="link-title"><a href="/link/#{link[:id]}">#{esc(link[:title])}</a></h2><div class="link-footer"><div class="link-tags">)
    tags.each { |t| s << %(<a href="/tag/#{esc(t[:name])}" class="tag-pill">#{esc(t[:name])}</a>) }
    s << %(</div><div class="link-author">by <a href="/user/#{esc(link[:username])}">#{esc(link[:username])}</a> <span class="link-time">#{time_ago(link[:created_at])}</span></div></div></div></article>)
  end
end

def build_sort_tabs(base_url : String, current_sort : String, tag_filter : String?) : String
  tag_param = tag_filter ? "tag=#{esc(tag_filter)}&" : ""
  String.build do |s|
    s << %(<div class="sort-tabs">)
    s << %(<a href="#{base_url}?#{tag_param}sort=newest" class="sort-tab #{current_sort == "newest" ? "active" : ""}">Newest</a>)
    s << %(<a href="#{base_url}?#{tag_param}sort=top" class="sort-tab #{current_sort == "top" ? "active" : ""}">Top</a>)
    s << %(</div>)
  end
end

# ── Seed ──────────────────────────────────────────────────

def seed_database
  count = APP_DB.scalar("SELECT COUNT(*) FROM users").as(Int64)
  return if count > 0
  puts "Seeding database..."

  users_data = [
    {username: "cenius", email: "cenius@cenius.ai", password: "cenius"},
    {username: "alice", email: "alice@example.com", password: "password123"},
    {username: "bob", email: "bob@example.com", password: "password123"},
    {username: "charlie", email: "charlie@example.com", password: "password123"},
    {username: "dave", email: "dave@example.com", password: "password123"},
    {username: "eve", email: "eve@example.com", password: "password123"},
  ]
  user_ids = [] of Int64
  users_data.each do |u|
    hash = Crypto::Bcrypt::Password.create(u[:password], cost: 10).to_s
    APP_DB.exec("INSERT INTO users (username, email, password_hash) VALUES (?, ?, ?)", u[:username], u[:email], hash)
    user_ids << APP_DB.scalar("SELECT last_insert_rowid()").as(Int64)
  end

  tag_names = ["AI", "Machine Learning", "Web", "JavaScript", "TypeScript", "Python", "Rust", "Go", "Crystal", "Database", "DevOps", "Security", "Open Source", "Mobile", "Design", "Startup", "Career", "Cloud", "API", "Performance"]
  tag_ids = {} of String => Int64
  tag_names.each do |name|
    APP_DB.exec("INSERT INTO tags (name) VALUES (?)", name)
    tag_ids[name] = APP_DB.scalar("SELECT last_insert_rowid()").as(Int64)
  end

  links_data = [
    {title: "Understanding Transformer Attention Mechanisms", url: "https://arxiv.org/example/attention", body: "A deep dive into how attention works in modern transformer architectures, including multi-head attention and flash attention optimizations.", tags: ["AI", "Machine Learning"], author: 0},
    {title: "Building a Custom Language Model from Scratch", url: "https://example.com/build-llm", body: "Step-by-step tutorial on creating a small language model using PyTorch, covering tokenization, embeddings, and training.", tags: ["AI", "Python"], author: 1},
    {title: "The State of WebAssembly in 2026", url: "https://example.com/wasm-2026", body: "WebAssembly has matured significantly. This post covers the latest WASI proposals, component model updates, and real-world adoption stories.", tags: ["Web", "Rust"], author: 2},
    {title: "Why I Switched from React to HTMX", url: "https://example.com/react-to-htmx", body: "After years of complex SPAs, moving to HTMX simplified our stack, reduced bundle size by 90%, and made the team happier.", tags: ["Web", "JavaScript"], author: 3},
    {title: "TypeScript 5.8: New Features and Breaking Changes", url: "https://devblogs.microsoft.com/typescript/ts58", body: "The latest TypeScript release brings const type parameters, improved type narrowing, and several quality-of-life improvements.", tags: ["TypeScript", "Web"], author: 4},
    {title: "Rust's Async Model: A Comprehensive Guide", url: "https://example.com/rust-async", body: "Understanding Rust's async/await, futures, and the executor ecosystem. Covers tokio, async-std, and the ongoing standardization efforts.", tags: ["Rust", "Performance"], author: 5},
    {title: "Building a Real-time Chat with Crystal and Kemal", url: "https://example.com/crystal-kemal-chat", body: "A practical guide to building real-time applications with Crystal's concurrency model and the lightweight Kemal framework.", tags: ["Crystal", "Web"], author: 0},
    {title: "Go 1.25: What's New in the Latest Release", url: "https://go.dev/blog/go1.25", body: "Go continues to evolve with improved generics, better error handling patterns, and new standard library additions.", tags: ["Go", "Open Source"], author: 1},
    {title: "PostgreSQL Performance Tuning for High-Traffic Apps", url: "https://example.com/pg-tuning", body: "Practical tips for tuning PostgreSQL: connection pooling, query optimization, indexing strategies, and vacuum configuration.", tags: ["Database", "Performance"], author: 2},
    {title: "Docker vs Podman: Which Container Runtime Should You Use?", url: "https://example.com/docker-vs-podman", body: "A comparison of Docker and Podman for development and production. Covers rootless containers, compose files, and CI/CD integration.", tags: ["DevOps", "Cloud"], author: 3},
    {title: "Zero-Trust Security Architecture Explained", url: "https://example.com/zero-trust", body: "An accessible introduction to zero-trust security: what it means, why it matters, and how to implement it incrementally in your organization.", tags: ["Security", "Cloud"], author: 4},
    {title: "The Rise of AI-Assisted Code Review", url: "https://example.com/ai-code-review", body: "How AI tools are changing code review workflows, catching bugs earlier, and freeing up senior developers for higher-level design work.", tags: ["AI", "Career"], author: 5},
    {title: "Flutter vs React Native: A 2026 Perspective", url: "https://example.com/flutter-vs-rn", body: "Both frameworks have matured. We compare development speed, performance, ecosystem, and platform support as of 2026.", tags: ["Mobile", "JavaScript"], author: 0},
    {title: "Designing Accessible Web Applications", url: "https://example.com/a11y-web", body: "Practical patterns for building web apps that work for everyone: semantic HTML, ARIA, keyboard navigation, and color contrast.", tags: ["Design", "Web"], author: 1},
    {title: "Bootstrapping a SaaS to $10K MRR", url: "https://example.com/saas-bootstrap", body: "The story of how a solo founder built a profitable SaaS without VC funding, covering product decisions, marketing, and pricing.", tags: ["Startup", "Career"], author: 2},
    {title: "Understanding gRPC: When and Why to Use It", url: "https://example.com/grpc-guide", body: "gRPC vs REST vs GraphQL: a decision framework for choosing the right API protocol for your next project.", tags: ["API", "Performance"], author: 3},
    {title: "The Future of Edge Computing", url: "https://example.com/edge-computing", body: "How edge computing is reshaping application architecture, from CDN-based functions to distributed databases at the edge.", tags: ["Cloud", "Web"], author: 4},
    {title: "Mastering Python's Asyncio", url: "https://example.com/python-asyncio", body: "A practical guide to Python's asyncio library: coroutines, tasks, event loops, and common patterns for concurrent IO-bound workloads.", tags: ["Python", "Performance"], author: 5},
    {title: "SQLite for Production Web Apps", url: "https://example.com/sqlite-prod", body: "SQLite is more capable than most developers think. This post covers WAL mode, concurrent readers, and deployment strategies.", tags: ["Database", "Web"], author: 0},
    {title: "Building CLI Tools in Rust", url: "https://example.com/rust-cli", body: "Why Rust is an excellent choice for command-line tools: fast startup, cross-compilation, and great libraries like clap and indicatif.", tags: ["Rust", "Open Source"], author: 1},
    {title: "Kubernetes for Small Teams: Is It Worth It?", url: "https://example.com/k8s-small-teams", body: "An honest assessment of Kubernetes for teams of 5-20 engineers. When it helps and when simpler alternatives are better.", tags: ["DevOps", "Cloud"], author: 2},
    {title: "The Art of Technical Writing", url: "https://example.com/technical-writing", body: "How to write clear, engaging technical content: structuring articles, choosing examples, and developing your voice.", tags: ["Career", "Design"], author: 3},
  ]
  link_ids = [] of Int64
  links_data.each do |l|
    APP_DB.exec("INSERT INTO links (title, url, body, user_id) VALUES (?, ?, ?, ?)", l[:title], l[:url], l[:body], user_ids[l[:author]])
    id = APP_DB.scalar("SELECT last_insert_rowid()").as(Int64)
    link_ids << id
    l[:tags].each do |tname|
      if tid = tag_ids[tname]?
        APP_DB.exec("INSERT OR IGNORE INTO link_tags (link_id, tag_id) VALUES (?, ?)", id, tid)
      end
    end
  end
  link_ids.each do |lid|
    num_votes = rand(2..8)
    user_ids.sample(num_votes).each do |uid|
      dir = rand(1..10) > 2 ? "up" : "down"
      begin
        APP_DB.exec("INSERT INTO votes (link_id, user_id, direction) VALUES (?, ?, ?)", lid, uid, dir)
      rescue; end
    end
  end
  comments_data = [
    {body: "Great article! I found the explanation of multi-head attention particularly clear.", link: 0, author: 1, parent: -1},
    {body: "Have you looked at grouped-query attention? It's been a game-changer for our inference pipeline.", link: 0, author: 2, parent: 0},
    {body: "We've been using GQA in production for about 6 months now. The memory savings are significant.", link: 0, author: 3, parent: 1},
    {body: "This is a really solid tutorial. I'd love to see a follow-up on fine-tuning techniques.", link: 1, author: 4, parent: -1},
    {body: "The WebAssembly component model is genuinely exciting. It finally makes WASM practical for real server-side use.", link: 2, author: 0, parent: -1},
    {body: "I made the same switch last year. The reduction in complexity is worth it alone.", link: 3, author: 5, parent: -1},
    {body: "How do you handle complex form interactions without React?", link: 3, author: 1, parent: 5},
    {body: "We use a combination of server-side validation and Stimulus. Works great for 90% of use cases.", link: 3, author: 3, parent: 6},
    {body: "The const type parameters feature is fantastic. Finally removes so much boilerplate.", link: 4, author: 2, parent: -1},
    {body: "Crystal's type system is incredible for web development. Catches so many bugs at compile time.", link: 6, author: 4, parent: -1},
    {body: "I've been using Kemal for side projects and it's been a joy. Impressive performance.", link: 6, author: 2, parent: 9},
    {body: "PgBouncer connection pooling reduced our Postgres latency by 60%.", link: 8, author: 5, parent: -1},
    {body: "Podman's rootless mode is the killer feature. Running containers without sudo is huge.", link: 9, author: 0, parent: -1},
    {body: "The key insight: network location shouldn't imply trust. Every request authenticated.", link: 10, author: 1, parent: -1},
    {body: "AI code review catches the obvious bugs humans miss when tired. Surprisingly effective.", link: 11, author: 3, parent: -1},
    {body: "Flutter's hot reload developer experience is still unmatched.", link: 12, author: 5, parent: -1},
    {body: "Accessibility isn't just right — it's good business. About 15% of users benefit.", link: 13, author: 2, parent: -1},
    {body: "Really appreciate the honesty. Building a SaaS is hard, and this shows it's possible without VC.", link: 14, author: 4, parent: -1},
    {body: "We use gRPC for internal services and REST for public APIs. Best of both worlds.", link: 15, author: 1, parent: -1},
    {body: "Edge computing shines for globally distributed apps. Our users in Asia saw 3x improvement.", link: 16, author: 0, parent: -1},
  ]
  comment_id_map = {} of Int32 => Int64
  comments_data.each_with_index do |c, idx|
    parent_id = c[:parent] >= 0 ? comment_id_map[c[:parent]]? : nil
    APP_DB.exec("INSERT INTO comments (body, user_id, link_id, parent_id) VALUES (?, ?, ?, ?)", c[:body], user_ids[c[:author]], link_ids[c[:link]], parent_id)
    comment_id_map[idx] = APP_DB.scalar("SELECT last_insert_rowid()").as(Int64)
  end
  puts "Seed complete: #{users_data.size} users, #{tag_names.size} tags, #{link_ids.size} links."
end

Kemal.config.public_folder = "./public"

# ── Routes ──────────────────────────────────────────────────

get "/" do |env|
  sort = (env.params.query["sort"]? || "newest")
  tag_filter = env.params.query["tag"]?.try(&.strip).presence
  page = {((env.params.query["page"]? || "1").to_i), 1}.max
  per_page = 25
  offset = (page - 1) * per_page

  order = sort == "top" ? "ORDER BY vote_count DESC, l.created_at DESC" : "ORDER BY l.created_at DESC"

  if tag_filter
    links = APP_DB.query_all("SELECT l.id, l.title, l.url, COALESCE(l.body,'') as body, l.user_id, u.username, l.created_at, COALESCE(SUM(CASE WHEN v.direction='up' THEN 1 WHEN v.direction='down' THEN -1 ELSE 0 END),0) as vote_count, COALESCE((SELECT COUNT(*) FROM comments c WHERE c.link_id=l.id),0) as comment_count FROM links l JOIN users u ON l.user_id = u.id LEFT JOIN votes v ON l.id = v.link_id WHERE l.id IN (SELECT lt.link_id FROM link_tags lt INNER JOIN tags t ON lt.tag_id = t.id WHERE t.name = ?) GROUP BY l.id #{order} LIMIT ? OFFSET ?", tag_filter, per_page, offset,
      as: {id: Int64, title: String, url: String, body: String, user_id: Int64, username: String, created_at: String, vote_count: Int64, comment_count: Int64})
    total = APP_DB.scalar("SELECT COUNT(*) FROM links l WHERE l.id IN (SELECT lt.link_id FROM link_tags lt INNER JOIN tags t ON lt.tag_id = t.id WHERE t.name = ?)", tag_filter).as(Int64)
  else
    links = APP_DB.query_all("SELECT l.id, l.title, l.url, COALESCE(l.body,'') as body, l.user_id, u.username, l.created_at, COALESCE(SUM(CASE WHEN v.direction='up' THEN 1 WHEN v.direction='down' THEN -1 ELSE 0 END),0) as vote_count, COALESCE((SELECT COUNT(*) FROM comments c WHERE c.link_id=l.id),0) as comment_count FROM links l JOIN users u ON l.user_id = u.id LEFT JOIN votes v ON l.id = v.link_id GROUP BY l.id #{order} LIMIT ? OFFSET ?", per_page, offset,
      as: {id: Int64, title: String, url: String, body: String, user_id: Int64, username: String, created_at: String, vote_count: Int64, comment_count: Int64})
    total = APP_DB.scalar("SELECT COUNT(*) FROM links").as(Int64)
  end

  body = String.build do |s|
    s << %(<div class="page-header"><div><h1 class="page-title">)
    if tag_filter; s << %(Links tagged <span class="tag-highlight">#{esc(tag_filter)}</span>); else; s << %(Latest Links); end
    s << %(</h1><p class="page-subtitle">#{total} links</p></div>)
    s << build_sort_tabs("/", sort, tag_filter)
    s << %(</div>)
    if links.empty?
      s << %(<div class="empty-state"><div class="empty-icon">&#128279;</div><h2>No links yet</h2><p>Be the first to share something interesting!</p>)
      if current_user(env)
        s << %(<a href="/submit" class="btn btn-primary">Submit a Link</a>)
      else
        s << %(<a href="/login" class="btn btn-primary">Log in to submit</a>)
      end
      s << %(</div>)
    else
      s << %(<div class="link-list">)
      links.each { |l| s << build_link_card(l) }
      s << %(</div>)
    end
  end

  build_layout(env, "Home", body)
end

get "/tag/:name" do |env|
  tag_name = env.params.url["name"]
  sort = (env.params.query["sort"]? || "newest")
  page = {((env.params.query["page"]? || "1").to_i), 1}.max
  per_page = 25
  offset = (page - 1) * per_page
  order = sort == "top" ? "ORDER BY vote_count DESC, l.created_at DESC" : "ORDER BY l.created_at DESC"

  links = APP_DB.query_all("SELECT l.id, l.title, l.url, COALESCE(l.body,'') as body, l.user_id, u.username, l.created_at, COALESCE(SUM(CASE WHEN v.direction='up' THEN 1 WHEN v.direction='down' THEN -1 ELSE 0 END),0) as vote_count, COALESCE((SELECT COUNT(*) FROM comments c WHERE c.link_id=l.id),0) as comment_count FROM links l JOIN users u ON l.user_id = u.id JOIN link_tags lt ON l.id = lt.link_id JOIN tags t ON lt.tag_id = t.id LEFT JOIN votes v ON l.id = v.link_id WHERE t.name = ? GROUP BY l.id #{order} LIMIT ? OFFSET ?", tag_name, per_page, offset,
    as: {id: Int64, title: String, url: String, body: String, user_id: Int64, username: String, created_at: String, vote_count: Int64, comment_count: Int64})
  total = APP_DB.scalar("SELECT COUNT(*) FROM links l JOIN link_tags lt ON l.id = lt.link_id JOIN tags t ON lt.tag_id = t.id WHERE t.name = ?", tag_name).as(Int64)

  if total == 0 && links.empty?
    body = %(<div class="error-page"><div class="error-code">404</div><h1 class="error-title">Tag not found</h1><p class="error-message">No links with tag "#{esc(tag_name)}" exist yet.</p><a href="/" class="btn btn-primary">Back to Home</a></div>)
    env.response.status_code = 404
  else
    body = String.build do |s|
      s << %(<div class="page-header"><div><h1 class="page-title">Tag: <span class="tag-highlight">#{esc(tag_name)}</span></h1><p class="page-subtitle">#{total} links</p></div>)
      s << build_sort_tabs("/tag/#{esc(tag_name)}", sort, nil)
      s << %(</div><div class="link-list">)
      links.each { |l| s << build_link_card(l) }
      s << %(</div>)
    end
  end

  build_layout(env, "Tag: #{tag_name}", body)
end

get "/link/:id" do |env|
  link_id = env.params.url["id"].to_i64
  user = current_user(env)

  link = APP_DB.query_one?("SELECT l.id, l.title, l.url, COALESCE(l.body,'') as body, l.user_id, u.username, l.created_at FROM links l JOIN users u ON l.user_id = u.id WHERE l.id = ?", link_id,
    as: {id: Int64, title: String, url: String, body: String, user_id: Int64, username: String, created_at: String})

  unless link
    body = %(<div class="error-page"><div class="error-code">404</div><h1 class="error-title">Link not found</h1><p class="error-message">This link doesn't exist or has been removed.</p><a href="/" class="btn btn-primary">Back to Home</a></div>)
    env.response.status_code = 404
    next build_layout(env, "Not Found", body)
  end

  tags = link_tags_for(link_id)
  vote_count = link_vote_count(link_id)
  comment_count = APP_DB.scalar("SELECT COUNT(*) FROM comments WHERE link_id = ?", link_id).as(Int64)
  uv = user_vote_dir(link_id, user.try(&.[:id]))
  domain = extract_domain(link[:url])

  all_comments = APP_DB.query_all("SELECT c.id, c.body, c.user_id, u.username, c.parent_id, c.created_at FROM comments c JOIN users u ON c.user_id = u.id WHERE c.link_id = ? ORDER BY c.created_at ASC", link_id,
    as: {id: Int64, body: String, user_id: Int64, username: String, parent_id: Int64?, created_at: String})

  root_comments = all_comments.select { |c| c[:parent_id].nil? }

  body = String.build do |s|
    s << %(<article class="link-detail"><header class="link-detail-header"><div class="link-vote-detail"><span class="vote-count-large">#{vote_count}</span><span class="vote-label">votes</span>)
    if user
      s << %(<form action="/vote" method="post" class="vote-form"><input type="hidden" name="link_id" value="#{link[:id]}"><button type="submit" name="direction" value="up" class="vote-btn #{uv == "up" ? "voted-up" : ""}" title="Upvote" aria-label="Upvote"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="18 15 12 9 6 15"></polyline></svg></button></form>)
    end
    s << %(</div><div class="link-detail-main"><h1 class="link-detail-title">#{esc(link[:title])}</h1>)
    s << %(<div class="link-detail-meta"><a href="#{esc(link[:url])}" class="link-detail-url" rel="nofollow noopener" target="_blank"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M18 13v6a2 2 0 01-2 2H5a2 2 0 01-2-2V8a2 2 0 012-2h6"></path><polyline points="15 3 21 3 21 9"></polyline><line x1="10" y1="14" x2="21" y2="3"></line></svg> #{esc(domain)}</a><span>by <a href="/user/#{esc(link[:username])}">#{esc(link[:username])}</a></span><span>#{time_ago(link[:created_at])}</span></div>)
    unless link[:body].empty?
      s << %(<div class="link-detail-body"><p>#{esc(link[:body])}</p></div>)
    end
    s << %(<div class="link-detail-tags">)
    tags.each { |t| s << %(<a href="/tag/#{esc(t[:name])}" class="tag-pill">#{esc(t[:name])}</a>) }
    s << %(</div></div></header>)
    s << %(<section class="comments-section"><div class="comments-header"><h2>Comments (#{comment_count})</h2></div>)
    if user
      s << %(<form action="/comment" method="post" class="comment-form"><input type="hidden" name="link_id" value="#{link[:id]}"><div class="comment-form-body"><textarea name="body" rows="3" placeholder="Share your thoughts..." required></textarea><button type="submit" class="btn btn-primary">Comment</button></div></form>)
    else
      s << %(<div class="comment-login-prompt"><p><a href="/login">Log in</a> to join the discussion.</p></div>)
    end
    s << %(<div class="comment-thread">)
    root_comments.each do |comment|
      children = all_comments.select { |c| c[:parent_id] == comment[:id] }
      s << %(<div class="comment-item"><div class="comment-main"><div class="comment-meta"><a href="/user/#{esc(comment[:username])}" class="comment-author">#{esc(comment[:username])}</a><span class="comment-time">#{time_ago(comment[:created_at])}</span></div><div class="comment-body"><p>#{esc(comment[:body])}</p></div></div>)
      children.each do |child|
        s << %(<div class="comment-item comment-reply"><div class="comment-main"><div class="comment-meta"><a href="/user/#{esc(child[:username])}" class="comment-author">#{esc(child[:username])}</a><span class="comment-time">#{time_ago(child[:created_at])}</span></div><div class="comment-body"><p>#{esc(child[:body])}</p></div></div></div>)
      end
      s << %(</div>)
    end
    s << %(</div></section></article>)
  end

  build_layout(env, esc(link[:title]), body)
end

get "/submit" do |env|
  uid = require_auth(env)
  next unless uid

  body = %(<div class="page-header"><h1 class="page-title">Submit a Link</h1></div><div class="form-container"><form action="/link" method="post" class="submit-form"><div class="form-group"><label for="title">Title <span class="required">*</span></label><input type="text" id="title" name="title" required placeholder="An interesting article title" maxlength="300"></div><div class="form-group"><label for="url">URL <span class="required">*</span></label><input type="url" id="url" name="url" required placeholder="https://example.com/article"></div><div class="form-group"><label for="body">Body <span class="optional">(optional)</span></label><textarea id="body" name="body" rows="4" placeholder="Add context, a summary, or your thoughts..."></textarea></div><div class="form-group"><label for="tags">Tags <span class="optional">(comma-separated)</span></label><input type="text" id="tags" name="tags" placeholder="e.g. AI, web, crystal"></div><div class="form-actions"><button type="submit" class="btn btn-primary">Submit Link</button><a href="/" class="btn btn-ghost">Cancel</a></div></form></div>)

  build_layout(env, "Submit", body)
end

post "/link" do |env|
  uid = require_auth(env)
  next unless uid

  title = env.params.body["title"]?.to_s.strip
  url = env.params.body["url"]?.to_s.strip
  body_text = env.params.body["body"]?.to_s.strip || ""
  tags_input = env.params.body["tags"]?.to_s.strip || ""

  if title.empty? || url.empty?
    env.response.status_code = 422
    body = %(<div class="page-header"><h1 class="page-title">Submit a Link</h1></div><div class="form-container"><div class="alert alert-error">Title and URL are required.</div><form action="/link" method="post" class="submit-form"><div class="form-group"><label for="title">Title <span class="required">*</span></label><input type="text" id="title" name="title" required placeholder="An interesting article title" maxlength="300" value="#{esc(title)}"></div><div class="form-group"><label for="url">URL <span class="required">*</span></label><input type="url" id="url" name="url" required placeholder="https://example.com/article" value="#{esc(url)}"></div><div class="form-group"><label for="body">Body <span class="optional">(optional)</span></label><textarea id="body" name="body" rows="4" placeholder="Add context, a summary, or your thoughts...">#{esc(body_text)}</textarea></div><div class="form-group"><label for="tags">Tags <span class="optional">(comma-separated)</span></label><input type="text" id="tags" name="tags" placeholder="e.g. AI, web, crystal" value="#{esc(tags_input)}"></div><div class="form-actions"><button type="submit" class="btn btn-primary">Submit Link</button><a href="/" class="btn btn-ghost">Cancel</a></div></form></div>)
    next build_layout(env, "Submit", body)
  end

  APP_DB.exec("INSERT INTO links (title, url, body, user_id) VALUES (?, ?, ?, ?)", title, url, body_text, uid)
  link_id = APP_DB.scalar("SELECT last_insert_rowid()").as(Int64)

  tags_input.split(",").each do |tname|
    tname = tname.strip.downcase
    next if tname.empty?
    existing = APP_DB.query_one?("SELECT id FROM tags WHERE LOWER(name) = ?", tname, as: Int64)
    tid = if existing
      existing
    else
      APP_DB.exec("INSERT INTO tags (name) VALUES (?)", tname)
      APP_DB.scalar("SELECT last_insert_rowid()").as(Int64)
    end
    APP_DB.exec("INSERT OR IGNORE INTO link_tags (link_id, tag_id) VALUES (?, ?)", link_id, tid)
  end

  env.response.status_code = 302
  env.response.headers["Location"] = "/link/#{link_id}"
end

post "/vote" do |env|
  uid = require_auth(env)
  next unless uid

  link_id = env.params.body["link_id"]?.to_s.to_i64
  direction = env.params.body["direction"]?.to_s || "up"
  unless direction.in?(["up", "down"])
    env.response.content_type = "application/json"
    next {success: false, error: "Invalid direction"}.to_json
  end

  existing = APP_DB.query_one?("SELECT id, direction FROM votes WHERE link_id = ? AND user_id = ?", link_id, uid, as: {id: Int64, direction: String})
  if existing
    if existing[:direction] == direction
      APP_DB.exec("DELETE FROM votes WHERE id = ?", existing[:id])
    else
      APP_DB.exec("UPDATE votes SET direction = ?, created_at = datetime('now') WHERE id = ?", direction, existing[:id])
    end
  else
    APP_DB.exec("INSERT INTO votes (link_id, user_id, direction) VALUES (?, ?, ?)", link_id, uid, direction)
  end

  count = link_vote_count(link_id)
  uv_new = user_vote_dir(link_id, uid)
  env.response.content_type = "application/json"
  {success: true, votes_count: count, user_vote: uv_new}.to_json
end

post "/comment" do |env|
  uid = require_auth(env)
  next unless uid

  link_id = env.params.body["link_id"]?.to_s.to_i64
  body_text = env.params.body["body"]?.to_s.strip
  parent_id_str = env.params.body["parent_id"]?.to_s.strip

  if body_text.empty?
    env.response.status_code = 302
    env.response.headers["Location"] = "/link/#{link_id}"
    next
  end

  parent_id = parent_id_str.empty? ? nil : parent_id_str.to_i64
  APP_DB.exec("INSERT INTO comments (body, user_id, link_id, parent_id) VALUES (?, ?, ?, ?)", body_text, uid, link_id, parent_id)

  env.response.status_code = 302
  env.response.headers["Location"] = "/link/#{link_id}"
end

get "/login" do |env|
  if current_user(env)
    env.response.status_code = 302
    env.response.headers["Location"] = "/"
    next
  end
  body = %(<div class="page-header"><h1 class="page-title">Log in</h1></div><div class="form-container form-auth"><div class="demo-hint"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"></circle><line x1="12" y1="16" x2="12" y2="12"></line><line x1="12" y1="8" x2="12.01" y2="8"></line></svg><span>Demo: <strong>cenius@cenius.ai</strong> / <strong>cenius</strong></span></div><form action="/login" method="post"><div class="form-group"><label for="email">Email</label><input type="email" id="email" name="email" required autocomplete="email" placeholder="you@example.com"></div><div class="form-group"><label for="password">Password</label><input type="password" id="password" name="password" required autocomplete="current-password"></div><div class="form-actions"><button type="submit" class="btn btn-primary btn-full">Log in</button></div><p class="form-alt-link">Don't have an account? <a href="/register">Sign up</a></p></form></div>)
  build_layout(env, "Log in", body)
end

post "/login" do |env|
  email = env.params.body["email"]?.to_s.strip
  password = env.params.body["password"]?.to_s

  row = APP_DB.query_one?("SELECT id, username, email, password_hash FROM users WHERE email = ?", email,
    as: {id: Int64, username: String, email: String, password_hash: String})

  if row
    begin
      if Crypto::Bcrypt::Password.new(row[:password_hash]).verify(password)
        set_session(env, row[:id])
        env.response.status_code = 302
        env.response.headers["Location"] = "/"
        next
      end
    rescue; end
  end

  env.response.status_code = 401
  body = %(<div class="page-header"><h1 class="page-title">Log in</h1></div><div class="form-container form-auth"><div class="demo-hint"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="10"></circle><line x1="12" y1="16" x2="12" y2="12"></line><line x1="12" y1="8" x2="12.01" y2="8"></line></svg><span>Demo: <strong>cenius@cenius.ai</strong> / <strong>cenius</strong></span></div><div class="alert alert-error">Invalid email or password.</div><form action="/login" method="post"><div class="form-group"><label for="email">Email</label><input type="email" id="email" name="email" required autocomplete="email" placeholder="you@example.com" value="#{esc(email)}"></div><div class="form-group"><label for="password">Password</label><input type="password" id="password" name="password" required autocomplete="current-password"></div><div class="form-actions"><button type="submit" class="btn btn-primary btn-full">Log in</button></div><p class="form-alt-link">Don't have an account? <a href="/register">Sign up</a></p></form></div>)
  build_layout(env, "Log in", body)
end

get "/register" do |env|
  if current_user(env)
    env.response.status_code = 302
    env.response.headers["Location"] = "/"
    next
  end
  body = %(<div class="page-header"><h1 class="page-title">Create an account</h1></div><div class="form-container form-auth"><form action="/register" method="post"><div class="form-group"><label for="username">Username</label><input type="text" id="username" name="username" required autocomplete="username" placeholder="yourname" minlength="2" maxlength="30"></div><div class="form-group"><label for="email">Email</label><input type="email" id="email" name="email" required autocomplete="email" placeholder="you@example.com"></div><div class="form-group"><label for="password">Password</label><input type="password" id="password" name="password" required autocomplete="new-password" minlength="6" placeholder="At least 6 characters"></div><div class="form-group"><label for="password_confirmation">Confirm Password</label><input type="password" id="password_confirmation" name="password_confirmation" required autocomplete="new-password" minlength="6"></div><div class="form-actions"><button type="submit" class="btn btn-primary btn-full">Create Account</button></div><p class="form-alt-link">Already have an account? <a href="/login">Log in</a></p></form></div>)
  build_layout(env, "Register", body)
end

post "/register" do |env|
  username = env.params.body["username"]?.to_s.strip
  email = env.params.body["email"]?.to_s.strip
  password = env.params.body["password"]?.to_s
  password_confirmation = env.params.body["password_confirmation"]?.to_s

  errors = [] of String
  if username.empty?; errors << "Username is required."
  elsif username.size < 2 || username.size > 30; errors << "Username must be 2-30 characters."
  end
  if email.empty?; errors << "Email is required."
  elsif !email.includes?("@"); errors << "Email is not valid."
  end
  if password.nil? || password.empty?; errors << "Password is required."
  elsif password.size < 6; errors << "Password must be at least 6 characters."
  end
  if password != password_confirmation; errors << "Password confirmation doesn't match."; end

  if username.size > 0
    if APP_DB.query_one?("SELECT id FROM users WHERE username = ?", username, as: Int64)
      errors << "Username is already taken."
    end
  end
  if email.size > 0
    if APP_DB.query_one?("SELECT id FROM users WHERE email = ?", email, as: Int64)
      errors << "Email is already registered."
    end
  end

  unless errors.empty?
    env.response.status_code = 422
    err_html = errors.map { |e| "<li>#{esc(e)}</li>" }.join
    body = %(<div class="page-header"><h1 class="page-title">Create an account</h1></div><div class="form-container form-auth"><div class="alert alert-error"><ul>#{err_html}</ul></div><form action="/register" method="post"><div class="form-group"><label for="username">Username</label><input type="text" id="username" name="username" required autocomplete="username" placeholder="yourname" minlength="2" maxlength="30" value="#{esc(username)}"></div><div class="form-group"><label for="email">Email</label><input type="email" id="email" name="email" required autocomplete="email" placeholder="you@example.com" value="#{esc(email)}"></div><div class="form-group"><label for="password">Password</label><input type="password" id="password" name="password" required autocomplete="new-password" minlength="6" placeholder="At least 6 characters"></div><div class="form-group"><label for="password_confirmation">Confirm Password</label><input type="password" id="password_confirmation" name="password_confirmation" required autocomplete="new-password" minlength="6"></div><div class="form-actions"><button type="submit" class="btn btn-primary btn-full">Create Account</button></div><p class="form-alt-link">Already have an account? <a href="/login">Log in</a></p></form></div>)
    next build_layout(env, "Register", body)
  end

  hash = Crypto::Bcrypt::Password.create(password, cost: 10).to_s
  APP_DB.exec("INSERT INTO users (username, email, password_hash) VALUES (?, ?, ?)", username, email, hash)
  new_id = APP_DB.scalar("SELECT last_insert_rowid()").as(Int64)
  set_session(env, new_id)
  env.response.status_code = 302
  env.response.headers["Location"] = "/"
end

get "/logout" do |env|
  clear_session(env)
  env.response.status_code = 302
  env.response.headers["Location"] = "/"
end

get "/search" do |env|
  query = env.params.query["q"]?.to_s.strip
  sort = (env.params.query["sort"]? || "newest")

  if query.nil? || query.empty?
    body = %(<div class="page-header"><h1 class="page-title">Search</h1></div><form action="/search" method="get" class="search-form-page"><div class="search-input-group"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" class="search-icon"><circle cx="11" cy="11" r="8"></circle><line x1="21" y1="21" x2="16.65" y2="16.65"></line></svg><input type="search" name="q" placeholder="Search links, tags, and discussions..." autofocus></div></form>)
    next build_layout(env, "Search", body)
  end

  order = sort == "top" ? "ORDER BY vote_count DESC, l.created_at DESC" : "ORDER BY l.created_at DESC"
  search_param = "%#{query}%"

  links = APP_DB.query_all("SELECT DISTINCT l.id, l.title, l.url, COALESCE(l.body,'') as body, l.user_id, u.username, l.created_at, COALESCE(SUM(CASE WHEN v.direction='up' THEN 1 WHEN v.direction='down' THEN -1 ELSE 0 END),0) as vote_count, COALESCE((SELECT COUNT(*) FROM comments c WHERE c.link_id=l.id),0) as comment_count FROM links l JOIN users u ON l.user_id = u.id LEFT JOIN votes v ON l.id = v.link_id LEFT JOIN link_tags lt ON l.id = lt.link_id LEFT JOIN tags t ON lt.tag_id = t.id WHERE l.title LIKE ? OR l.body LIKE ? OR t.name LIKE ? GROUP BY l.id #{order} LIMIT 50", search_param, search_param, search_param,
    as: {id: Int64, title: String, url: String, body: String, user_id: Int64, username: String, created_at: String, vote_count: Int64, comment_count: Int64})

  body = String.build do |s|
    s << %(<div class="page-header"><h1 class="page-title">Search</h1></div>)
    s << %(<form action="/search" method="get" class="search-form-page"><div class="search-input-group"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" class="search-icon"><circle cx="11" cy="11" r="8"></circle><line x1="21" y1="21" x2="16.65" y2="16.65"></line></svg><input type="search" name="q" value="#{esc(query)}" placeholder="Search links, tags, and discussions..." autofocus></div>)
    s << build_sort_tabs("/search", sort, nil).sub("?sort", "?q=#{esc(query)}&sort")
    s << %(</form><div class="search-results-header"><p>#{links.size} result#{links.size == 1 ? "" : "s"} for "<strong>#{esc(query)}</strong>"</p></div>)
    if links.empty?
      s << %(<div class="empty-state"><div class="empty-icon">&#128269;</div><h2>No results found</h2><p>Try different keywords or browse the <a href="/">homepage</a>.</p></div>)
    else
      s << %(<div class="link-list">)
      links.each { |l| s << build_link_card(l) }
      s << %(</div>)
    end
  end

  build_layout(env, "Search: #{query}", body)
end

get "/user/:username" do |env|
  username = env.params.url["username"]

  profile = APP_DB.query_one?("SELECT id, username, email, created_at FROM users WHERE username = ?", username,
    as: {id: Int64, username: String, email: String, created_at: String})

  unless profile
    body = %(<div class="error-page"><div class="error-code">404</div><h1 class="error-title">User not found</h1><p class="error-message">No user named "#{esc(username)}" exists.</p><a href="/" class="btn btn-primary">Back to Home</a></div>)
    env.response.status_code = 404
    next build_layout(env, "Not Found", body)
  end

  profile_links = APP_DB.query_all("SELECT l.id, l.title, l.url, l.created_at, COALESCE(SUM(CASE WHEN v.direction='up' THEN 1 WHEN v.direction='down' THEN -1 ELSE 0 END),0) as vote_count, COALESCE((SELECT COUNT(*) FROM comments c WHERE c.link_id=l.id),0) as comment_count FROM links l LEFT JOIN votes v ON l.id = v.link_id WHERE l.user_id = ? GROUP BY l.id ORDER BY l.created_at DESC LIMIT 50", profile[:id],
    as: {id: Int64, title: String, url: String, created_at: String, vote_count: Int64, comment_count: Int64})

  profile_comments = APP_DB.query_all("SELECT c.id, c.body, c.created_at, c.link_id, l.title as link_title FROM comments c JOIN links l ON c.link_id = l.id WHERE c.user_id = ? ORDER BY c.created_at DESC LIMIT 50", profile[:id],
    as: {id: Int64, body: String, created_at: String, link_id: Int64, link_title: String})

  body = String.build do |s|
    initial = profile[:username][0, 1].upcase
    s << %(<div class="profile-page"><header class="profile-header"><div class="profile-avatar">#{esc(initial)}</div><div class="profile-info"><h1 class="profile-username">#{esc(profile[:username])}</h1><p class="profile-joined">Joined #{profile[:created_at][0, 10]}</p></div></header><div class="profile-sections">)
    s << %(<section class="profile-section"><h2 class="section-title">Submitted Links (#{profile_links.size})</h2>)
    if profile_links.empty?
      s << %(<p class="profile-empty">No links submitted yet.</p>)
    else
      s << %(<div class="profile-link-list">)
      profile_links.each do |plink|
        ptags = link_tags_for(plink[:id])
        s << %(<div class="profile-link-item"><div class="profile-link-main"><a href="/link/#{plink[:id]}" class="profile-link-title">#{esc(plink[:title])}</a><div class="profile-link-meta"><span>#{plink[:vote_count]} votes</span><span>#{plink[:comment_count]} comments</span><span>#{time_ago(plink[:created_at])}</span></div><div class="link-tags">)
        ptags.each { |t| s << %(<a href="/tag/#{esc(t[:name])}" class="tag-pill tag-pill-sm">#{esc(t[:name])}</a>) }
        s << %(</div></div></div>)
      end
      s << %(</div>)
    end
    s << %(</section><section class="profile-section"><h2 class="section-title">Recent Comments (#{profile_comments.size})</h2>)
    if profile_comments.empty?
      s << %(<p class="profile-empty">No comments yet.</p>)
    else
      s << %(<div class="profile-comment-list">)
      profile_comments.each do |pcom|
        s << %(<div class="profile-comment-item"><p class="profile-comment-body">#{esc(pcom[:body])}</p><div class="profile-comment-meta"><span>on <a href="/link/#{pcom[:link_id]}">#{esc(pcom[:link_title])}</a></span><span>#{time_ago(pcom[:created_at])}</span></div></div>)
      end
      s << %(</div>)
    end
    s << %(</section></div></div>)
  end

  build_layout(env, esc(profile[:username]), body)
end

get "/health" do
  "ok"
end

error 404 do |env|
  body = %(<div class="error-page"><div class="error-code">404</div><h1 class="error-title">Page not found</h1><p class="error-message">The page you're looking for doesn't exist or has been removed.</p><a href="/" class="btn btn-primary">Back to Home</a></div>)
  build_layout(env, "Not Found", body)
end

error 500 do |env, err|
  puts "500 Error: #{err.message}"
  puts err.backtrace?.try &.join("\n")
  body = %(<div class="error-page"><div class="error-code">500</div><h1 class="error-title">Something went wrong</h1><p class="error-message">An unexpected error occurred. Please try again later.</p><a href="/" class="btn btn-primary">Back to Home</a></div>)
  build_layout(env, "Error", body)
end

puts "Creating schema..."
create_schema
puts "Seeding database..."
seed_database
puts "Database ready."

Kemal.config.host_binding = HOST_BINDING
Kemal.config.port = PORT
Kemal.config.env = "production"
puts "Lumen starting on #{HOST_BINDING}:#{PORT}..."
Kemal.run
