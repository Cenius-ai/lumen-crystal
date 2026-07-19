# USAGE.md

Once Lumen is running (see [INSTALL.md](INSTALL.md)), open your browser at `http://localhost:3000`. Below is a guide to the main features and how to interact with them.

## Home Page

The home page (`/`) displays a list of submitted links, ordered by recency (or votes, depending on the implementation). Each link shows its title, URL, tags, and submission metadata.

**Example request:**
```bash
curl http://localhost:3000/
```

## Submitting a Link

Navigate to `/links/submit` or click the “Submit” button in the navigation bar. Fill in the form with a title, URL, and a comma-separated list of tags. After submission, you will be redirected to the newly created link’s page.

**Example submission (if the form uses POST):**
```bash
curl -X POST http://localhost:3000/links \
  -d "title=My Title&url=https://example.com&tags=tech,news"
```
*(Note: exact parameter names depend on the implementation; adjust accordingly.)*

## Viewing a Link

Each link has a detail page at `/links/:id` where you can see the full information and possibly comments or actions.

```bash
curl http://localhost:3000/links/1
```

## Browsing by Tag

Click on any tag (e.g., “tech”) to see all links associated with that tag at `/tags/:tag`.

```bash
curl http://localhost:3000/tags/tech
```

## Searching

Use the search box to perform a keyword search. Results appear at `/search?q=your+keywords`.

```bash
curl "http://localhost:3000/search?q=crystal"
```

## User Account

- **Register** at `/users/register`. Provide a username, email, and password.
- **Login** at `/users/login` with your credentials.
- **Profile** – after logging in, visit `/users/profile` to view and manage your account.

**Register example:**
```bash
curl -X POST http://localhost:3000/register \
  -d "username=jdoe&email=jdoe@example.com&password=secret"
```

**Login example:**
```bash
curl -X POST http://localhost:3000/login \
  -d "email=jdoe@example.com&password=secret"
```

*(The exact route names (e.g., `/register`, `/login`) should match the application’s routing; the above are typical but verify with the view names: `users/register.ecr`, `users/login.ecr`.)*

## Theme Toggle

The UI supports light and dark themes. Use the toggle button (likely in the header) to switch. The preference is stored in the browser’s local storage via `public/js/theme.js`.

## API Considerations

While Lumen is primarily a server‑rendered application (using ECR templates), most endpoints also return HTML. For programmatic access, you may add `.json` to the URL or set the `Accept: application/json` header, if the application supports it.