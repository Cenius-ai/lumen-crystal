# Lumen — open-source social network app

**Lumen** is a free, open-source social network app built with Crystal. Lumen is a tech news link aggregator built with Kemal (Crystal) that features full social functionality: user submissions with user-defined tags, upvoting/downvoting, threaded comments, and user accounts with email/pa…. Run it locally, deploy it as a self-hosted social network app, or [remix it on cenius.ai](https://cenius.ai/marketplace) to make it your own — the whole application (code, design, seeded demo data) ships in this repository under the MIT license.

[![License: MIT](https://img.shields.io/badge/License-MIT-16b881.svg)](LICENSE) ![Stack](https://img.shields.io/badge/Stack-Crystal-3b82f6) [![Built with cenius.ai](https://img.shields.io/badge/Built%20with-cenius.ai-8b5cf6)](https://cenius.ai)

## Demo

![Lumen demo — social network app built with Crystal](.github/media/hero.gif)

▶ Full walkthrough video: [`demo.mp4`](.github/media/demo.mp4)

## Screenshots

<img src=".github/media/shot-1.png" width="32%" alt="Lumen social network app screenshot 1"/> <img src=".github/media/shot-2.png" width="32%" alt="Lumen social network app screenshot 2"/> <img src=".github/media/shot-3.png" width="32%" alt="Lumen social network app screenshot 3"/>

## Features

- User Authentication
- Link Submission with Tags
- Voting
- Tagging System
- Commenting
- User Profiles
- Light/Dark Theme Toggle
- Search
- Responsive Design
- Browse by Tag and Sort

## Quick start

```bash
./install.sh   # installs dependencies + seeds demo data
```

See [`INSTALL.md`](INSTALL.md) for full setup and usage instructions.

## Usage guide

Once Lumen is running (see [INSTALL.md](INSTALL.md)), open your browser at `http://localhost:3000`. Below is a guide to the main features and how to interact with them.

### Home Page

The home page (`/`) displays a list of submitted links, ordered by recency (or votes, depending on the implementation). Each link shows its title, URL, tags, and submission metadata.

**Example request:**
```bash
curl http://localhost:3000/
```

### Submitting a Link

Navigate to `/links/submit` or click the “Submit” button in the navigation bar. Fill in the form with a title, URL, and a comma-separated list of tags. After submission, you will be redirected to the newly created link’s page.

**Example submission (if the form uses POST):**
```bash
curl -X POST http://localhost:3000/links \
  -d "title=My Title&url=https://example.com&tags=tech,news"
```
*(Note: exact parameter names depend on the implementation; adjust accordingly.)*

### Viewing a Link

Each link has a detail page at `/links/:id` where you can see the full information and possibly comments or actions.

```bash
curl http://localhost:3000/links/1
```

### Browsing by Tag

Click on any tag (e.g., “tech”) to see all links associated with that tag at `/tags/:tag`.

```bash
curl http://localhost:3000/tags/tech
```

### Searching

Use the search box to perform a keyword search. Results appear at `/search?q=your+keywords`.

```bash
curl "http://localhost:3000/search?q=crystal"
```

### User Account

_Full guide: [`USAGE.md`](USAGE.md)_

## Architecture

Crystal application, delivered as a complete, runnable project (254 files). Top-level layout: `bin/`, `lib/`, `public/`, `src/`, `views/`. `install.sh` provisions dependencies and seeds demo data, so the app boots with something to show. Setup details live in [`INSTALL.md`](INSTALL.md).

## FAQ

### How do I self-host Lumen?

Clone this repository and run `./install.sh`, then start the app as described in [`INSTALL.md`](INSTALL.md). Lumen is fully self-hostable — no external services are required to try it.

### Is Lumen free for commercial use?

Yes. The code is MIT-licensed — use it, modify it, and ship it commercially. See [LICENSE](LICENSE).

### Can I rebrand or white-label Lumen?

Yes — and the easiest way is [remixing it on cenius.ai](https://cenius.ai/marketplace): modifications made on the platform come with full rebrand and relicense rights over your derivative.

### How can I customize Lumen without editing code?

Open it on [cenius.ai](https://cenius.ai/marketplace) and describe the changes you want in plain English — the platform modifies the app and gives you a new, downloadable build.

### What is Lumen built with?

Crystal. The full source in this repository is exactly what the app runs.

## License & rebranding

Released under the [MIT License](LICENSE) (© 2026 Cenius AI) — free for personal and commercial use.

**Need a customized version?** [Remix this app on cenius.ai](https://cenius.ai/marketplace) — modifications made on the platform come with **full rebrand & relicense rights** over your derivative.

## Built with cenius.ai

This entire application — code, design, seeded demo data — was generated on **[cenius.ai](https://cenius.ai)** from a plain-English description.

- 🚀 [Build your own app on cenius.ai](https://cenius.ai)
- 🎛️ [Remix Lumen on the marketplace](https://cenius.ai/marketplace) — open it in a workspace, prompt for changes, and ship your own version.

More open-source apps: [the Cenius-ai catalog](https://github.com/Cenius-ai) · [showcase index](https://github.com/Cenius-ai/showcase)
