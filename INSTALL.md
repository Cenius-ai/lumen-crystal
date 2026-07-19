# INSTALL.md

## 1. Prerequisites

- **Crystal** (version 1.x or later)
- **shards** (comes with Crystal)
- SQLite3 library (available by default on most systems; ensure it is installed for Crystal’s SQLite3 bindings)

## 2. Get the Code

Clone the repository (or extract the source) into a local directory.

## 3. Install Dependencies

Run the following command to install all Crystal dependencies:

```bash
shards install
```

## 4. Database Setup

The application uses SQLite with the file `lumen.db` located in the project root. Ensure this file exists. If it is missing, the application may create it automatically on first run, depending on the schema initialization logic. No separate migration tool is required.

## 5. Running the Application (Development)

```bash
crystal run src
```

This starts the Kemal web server. The application will be available at `http://localhost:3000`.

## 6. Building for Production

To compile a standalone binary:

```bash
shards build
```

The binary will be placed in `bin/lumen`.

## 7. Testing

No test command is configured for this project.

## 8. Troubleshooting

- **Error: `shards` command not found**  
  Ensure Crystal is properly installed and `shards` is in your PATH.
- **Missing `lumen.db`**  
  Verify that the database file exists. If not, check for a setup script or manually run any initialization commands provided by the project (if available).
- **Port already in use**  
  If port 3000 is occupied, change the port in the source code (`src/lumen.cr`) or set the `PORT` environment variable before running (if supported by the application).
- **SQLite3 library errors**  
  Install the SQLite3 development package (e.g., `libsqlite3-dev` on Debian/Ubuntu, or `sqlite-devel` on CentOS).