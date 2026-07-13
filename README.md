# Warehouse

Warehouse is a self-hosted player for your iTunes/Music library. A macOS app
exports the library into a Postgres database and copies out the media files; a
Sinatra API server streams that library to a web app and an iOS/watchOS app; and
changes made while playing (plays, ratings, metadata edits) can be pushed back
into the local Music app.

## Components

- **export** — a macOS Swift app that reads the local iTunes/Music library into
  the database, symlinking music files into `music/` and copying artwork into
  `artwork/`.
- **server** — a Sinatra API server that backs the web and iOS apps.
- **web** — a React web app for playing the library.
- **ios** — an iOS app (in progress) similar to the web app, with a companion
  Apple Watch app.
- **update** — Ruby + AppleScript that takes changes (plays, metadata edits,
  artwork changes) recorded by the apps and pushes them back into the Music app.
- **changes** — snapshots the database to a day-stamped JSON file so you can
  diff the library between days.

## Configuration

Every component reads `config.yaml` at the repo root. Copy the example and edit
it:

- `cp config.yaml.example config.yaml`

It has a `local:` block (used on the macOS machine your library is present on),
a `remote:` block (used on a separate macOS or linux server), and a `users:` block
listing who can log in. Generate the JWT `secret` each block needs with:

- `ruby -rsecurerandom -e "puts SecureRandom.hex(32)"`

## Production

The server can run in either of two modes, chosen by which config block it
loads. Either way, first build the web app into `public/` (this also installs
the web dependencies and compiles the protobufs):

- `rake web:build`

You also need a populated database and the media files before the server is
useful — see [Exporting the iTunes library](#exporting-the-itunes-library).

### Local

Run the server on the same Mac as your Music library, using the `local:` config.
Sinatra serves the built web app and streams the music & artwork files directly
(via `send_file`), so no nginx is needed:

- `rake server:local`

It listens on the port from the `local:` block (20601), so open
`http://<machine>:20601`. To reach it from other devices, expose it over
Tailscale (see [Syncing the Apple Watch](#syncing-the-apple-watch)).

### Remote

Run the server on a separate macOS or Linux box, using the `remote:` config.
First copy the database and the `music/` & `artwork/` files onto that box. The
server then runs behind nginx: nginx terminates TLS, serves the built web app's
static files, and reverse-proxies the API to Puma over a unix socket. Music and
artwork are served efficiently via nginx `X-Accel-Redirect` — the Sinatra app
authorizes each request, then hands the actual file transfer back to nginx.

1. Configure nginx. Copy `nginx.conf.example` to
   `/etc/nginx/conf.d/warehouse.conf`, then edit the domain, TLS cert paths,
   `root` (point it at this repo's `public/`), the `listen` addresses, and the
   `/accel/music/` and `/accel/artwork/` aliases (point them at your `music/`
   and `artwork/` dirs). It's strongly recommended to bind the main `listen` to
   your Tailscale IP rather than a public interface.

2. Run the server with the remote config. It binds to the unix socket named by
   `socket_path` in the `remote:` block, which must match the `upstream` in the
   nginx config:

   - `rake server:remote`

The web app is then reachable at whatever address nginx listens on.

## Running locally

For day-to-day development, run the API server and the Vite dev server (hot
reload) in two terminals — this is distinct from the built-app
[Local](#local) production instance above. The server uses the `local:` config
(Sinatra on port 20601); the Vite dev server runs on 20602 and proxies `/api`,
`/music`, `/artwork` and `/download` through to it.

In one terminal:

- `rake server:local`

In another:

- `rake web:vite`

Then open `http://localhost:20602`.

To work against a smaller dataset, `rake db:trim` cuts the local database down
to 100 tracks (leaving the media files alone).

## Exporting the iTunes library

The macOS Warehouse Export app reads the local iTunes library into the
database and symlinks/copies the music & artwork files.

> **Run `rake update` before every export.** The web and iOS apps record plays,
> ratings, and metadata/artwork edits straight into the database. `rake
export:run` rebuilds that database from your current Music library, so any of
> those changes not yet written back to Music would be lost. `rake update`
> pushes them into Music first (via AppleScript). The
> [full sync](#syncing-the-library) below runs it as step one.

The headless export relies on two pieces of state it can't establish on its
own: a persisted bookmark for the workspace directory (which holds
`config.yaml` and the music/artwork dirs), and the macOS music-library access
grant. Both are set through the app's UI, so on a fresh machine run the
one-time setup first:

- `rake export:setup`

This builds the app and launches its window. Click **request authorization**
to grant music-library access, then **update workspace dir** to pick the
workspace (the repo root). Both persist, so you only need to do this once.

After that, build and run the export headless:

- `rake export:run`

This builds the app (scheme `warehouse-export`, Release) into the gitignored
`export/build/` directory and then launches it headless, streaming progress from
`export.log` until the export finishes or fails. Use `rake export:fast` for a
faster, less thorough pass, or `rake export:build` to just compile the app
without running it.

## Syncing the library

The end-to-end routine to refresh the library from Music and, optionally, push
it to a [remote](#remote) server. Run it from the repo root. `<server>` is the
ssh host of your remote box, and you start/stop the server however you manage it
(a process manager, systemd, etc.).

First, refresh locally:

```bash
rake update          # push app-side plays/ratings/edits back into Music FIRST,
                     # before the database is rebuilt and they would be lost
# stop the local server
rake export:run      # rebuild the database + music/artwork from the library
rake web:build       # rebuild the web app into public/
# start the local server
```

For a local production instance that's everything. To deploy to a remote
server, push the database, code, and media to it:

```bash
# stop the server on <server> so nothing holds a connection to the database

# drop and recreate the remote database from a fresh dump. these connect through
# a second database (warehouse-temp) because you can't drop the database you're
# connected to; pg_dump's -C emits the CREATE DATABASE. warehouse-temp must
# already exist on the server as a throwaway connection point.
echo "DROP DATABASE IF EXISTS warehouse;" | ssh -C <server> "psql -U warehouse warehouse-temp"
pg_dump -U warehouse -C warehouse | ssh -C <server> "psql -U warehouse warehouse-temp"

# sync the code, minus the media files and local-only change snapshots
rsync --archive --compress --itemize-changes --delete-during \
  --exclude 'artwork/' --exclude 'music/' \
  --exclude 'changes/tracks/' --exclude 'changes/playlists/' \
  ./ <server>:~/warehouse/server/

ssh <server> "cd warehouse/server && rake server:install"

# start the server on <server>

# sync artwork, then music. --copy-links dereferences the symlinks export leaves
# under music/, so the real audio files land on the server rather than symlinks.
rsync --archive --compress --itemize-changes --delete-during \
  ./artwork/ <server>:~/warehouse/artwork/
rsync --archive --compress --itemize-changes --delete-during --copy-links \
  ./music/ <server>:~/warehouse/music/
```

## Syncing the Apple Watch

The watch app downloads music & artwork straight from the server over wifi.
To keep the number of network requests down, the watch registers a bundle of
the files it's missing (up to 50 music files or 1000 artwork files at a time)
with `POST /api/bundle`, and the server builds a tar it then downloads with a
single background request. Only one transfer is in flight at a time, and the
chain keeps advancing while the app is suspended (background URLSession), so
big libraries sync overnight — faster with the watch on its charger.

watchOS can't join a tailnet (there's no VPN support and Go can't target
watchOS), so when the server is only reachable over Tailscale, temporarily
expose it with [Tailscale Funnel](https://tailscale.com/docs/features/tailscale-funnel)
while syncing:

- The nginx config has a second, plain-http listener on `127.0.0.1:20601`
  for Funnel to proxy to. Funnel can only target a localhost TCP port — it
  can't talk to Puma's unix socket, and pointing it at Puma directly would
  break downloads anyway, since `/music/`, `/artwork/` & `/bundle/` responses
  are empty `X-Accel-Redirect` replies that only nginx knows how to fulfill.
- On the server, run `rake server:funnel` while syncing (it runs
  `tailscale funnel --https=443 20601`; ctrl-c to stop). Funnel terminates
  TLS on the public port 443 and forwards plain http to nginx on 20601.
- In the iOS app, set the watch sync URL under Settings → Playlists to Sync
  to `https://<machine>.<tailnet>.ts.net`. That connects on the public Funnel
  port 443 (the https default, so no port suffix) — **not** nginx's internal
  `20601`, which is never exposed publicly. Leave it blank if the watch can
  reach the same server URL the phone uses.

Every `/api/`, `/music/`, `/artwork/` & `/bundle/` route requires a valid JWT,
so while the funnel is up the unauthenticated surface is just the login
endpoint and the web app's static files.

## Development

Useful tasks:

- `rake proto` — recompile the protobuf definitions (`messages.proto`) into
  Ruby, TypeScript, and Swift after editing the schema.
- `rake server:spec` — run the server tests.
- `rake web:vitest` — run the web tests once (`rake web:vitest_watch` to watch,
  or `rake web:vitest_browser` for the browser-mode suite, which needs
  playwright chromium).
- `rake ios:build` — build the iOS app for the simulator.
- `rake ios:test` / `rake ios:uitest` — run the iOS unit and UI tests (override
  the simulator with `SIMULATOR=...`).
- `rake ios:testflight` — archive the iOS app and upload it to TestFlight (see
  the task's comments in the `Rakefile` for the required App Store Connect key).
- `rake checks` — run the Ruby and web linting and formatting checks.

The `changes` component snapshots the database for diffing over time:

- `rake changes:archive` / `rake changes:diff` / `rake changes:rewind` —
  snapshot the database for a given day, diff the two newest snapshots, and
  list this year's most-played tracks.
