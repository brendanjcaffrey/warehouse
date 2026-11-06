# Warehouse

Warehouse is a self-hosted player for your iTunes/Music library. A macOS app
exports the library into a Postgres database and copies out the media files; a
Sinatra API server supplies that library to a web app and an iOS app; and
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
Tailscale. The Apple Watch receives its library through the paired phone.

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

Before running a headless export, use the app to choose the workspace directory
and grant access to your Music library:

- `rake export:setup`

This builds the app and opens its window. Click **Request Authorization**
to grant music-library access, then **Choose Workspace…** to pick the repo root.
Click **Allow Music Automation** and approve control of Music so the exporter
can read lyrics. The app saves the directory and permissions for future runs.
If automation was denied, enable Warehouse Export in
**System Settings → Privacy & Security → Automation → Music** before retrying.
Headless runs fail if this permission is missing.

After that, build and run the export headless:

- `rake export:run`

This builds the app (scheme `warehouse-export`, Release) into the gitignored
`export/build/` directory and then launches it headless, streaming progress from
`export.log` until the export finishes or fails. Use `rake export:fast` for a
faster, less thorough pass, or `rake export:build` to just compile the app
without running it.

Both full and fast exports read current lyrics and comments from Music,
preserving whitespace, line breaks and Unicode. Fast mode reuses existing
media filenames. Lyrics are handled according to Music's file type:

| Lyrics policy       | File types                                                                                     |
| ------------------- | ---------------------------------------------------------------------------------------------- |
| Read from Music     | `MPEG audio file`, `AAC audio file`, `Purchased AAC audio file`, `Purchased MPEG-4 video file` |
| Assume empty lyrics | `WAV audio file`                                                                               |

Comments are included for all supported file types, including WAV. An unknown
file type or failed lyrics read stops export before the database is rebuilt.

`rake update` writes queued lyrics and comments back to Music independently,
including empty values that clear a field. Local updates are applied first,
then remote updates; a remote edit to the same field wins. Queued edits can
overwrite direct Music edits. Text writes use JavaScript for Automation through
`osascript`, with JSON request files to preserve line breaks and special characters.

If Music retains embedded lyrics after a clear, the updater removes the lyrics
frames from supported MP3 ID3v2.3/v2.4 tags, refreshes Music and retries once.
It first saves a complete `.warehouse-lyrics-*.bak` backup beside the original
file, preserving audio and other metadata. Unsupported tag layouts or a failed
read-back still stop the update.

## Syncing the library

Run these commands from the repo root to refresh the library from Music.
The later steps copy it to a [remote](#remote) server if needed. `<server>` is
the ssh host of your remote box. Start and stop the server using your usual
process manager.

Freeze both libraries first, or anything an app writes between `rake update`
fetching the remote's changes and the database being replaced is dropped. Frozen
refuses writes and the apps will retry later.

```bash
rake freeze:local
ssh <server> "cd warehouse/server && rake freeze:remote"
```

Then refresh locally:

```bash
rake update          # push app-side plays/ratings/edits back into Music FIRST,
                     # before the database is rebuilt and they would be lost
# stop the local server
rake export:run      # rebuild the database + music/artwork from the library
rake web:build       # rebuild the web app into public/
# start the local server
```

`rake export:run` recreates every table, so the local library comes back unfrozen.

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

The remote unfreezes itself: the dump replaces its `library_state` row with the
local one, and it happens while the remote server is stopped.

## Lyrics and comments

On iPhone and iPad, tap the Lyrics button in Now Playing to read the current
track's saved lyrics. The reader follows playback and returns to the top when
the track changes. Choose Lyrics or Comments from a track's menu to keep reading
that track instead. Both readers work offline after library sync.

When editing is available, Edit opens the existing Edit Track form with Save and
Cancel. Playback changes leave that editor on its original track. Read-only
libraries still offer the readers. Lyrics and comments are not sent to the watch.

## The Apple Watch library

In the iPhone app, open **Settings → Apple Watch** and select playlists. The phone
supplies their metadata, music and artwork automatically whenever the system
permits.

The watch browses its saved library and plays downloaded songs without the phone.
Missing songs stay dimmed and cannot be played. Missing artwork uses a placeholder
until it arrives. Playlist edits and deselection mirror automatically, retaining
shared music and protecting active playback. Storage Full preserves downloaded
selected songs and retries missing delivery when space permits. Free space or
deselect playlists on the phone to release storage.

## Development

Useful tasks:

- `rake proto` — recompile the protobuf definitions (`messages.proto`) into
  Ruby, TypeScript, and Swift after editing the schema.
- `rake export:test` — run exporter tests using temporary tables in
  `warehouse_test`, with the same database credentials as the server specs.
- `rake server:spec` — run the server tests.
- `rake update:spec` — run updater and Music automation boundary specs with
  Music calls and remote responses stubbed. On macOS, this also exercises real
  `osascript` text transport with an in-memory Music stub.
- `rake web:vitest` — run the web tests once (`rake web:vitest_watch` to watch,
  or `rake web:vitest_browser` for the browser-mode suite, which needs
  playwright chromium).
- `rake ios:build` — build the iOS app for the simulator.
- `rake ios:lint` — run strict SwiftLint checks for iOS and watch sources and
  tests. Use SwiftLint 0.65.1 or newer to catch the violations checked by CI.
  CI loads the same task with `rake -f ios/lint.rake ios:lint` to avoid
  installing the server's Ruby dependencies.
- `rake ios:test` / `rake ios:uitest` — run the iOS unit and UI tests (override
  the simulator with `SIMULATOR=...`). Local unit tests and both CI suites run
  serially. CI has a 60-minute job limit and retries failed UI cases once to
  tolerate simulator lifecycle failures. CI excludes
  `WatchContentWorkerTests.responsiveness()` because its timing limit is
  unreliable on shared runners, and
  `WarehouseUITests.testAppleWatchDiagnosticsDatesSharingAndSwipeDeletion()`
  because system share-sheet presentation is flaky there. Both remain enabled
  locally. Unit tests and CI UI tests disable verbose diagnostic collection;
  to enable it, rerun the printed `xcodebuild` command with
  `-collect-test-diagnostics on-failure`.
  See [Apple's explanation of the option](https://developer.apple.com/forums/thread/698054).
  Failed CI unit-test runs print the result summary and each failing test's
  details, including assertions, source locations and parameter values.
  They retain the full bundle as `ios-unit-test-results` for 14 days.
  Download it with `gh run download <run-id> --name ios-unit-test-results
  --dir /tmp/ios-unit-tests.xcresult`, then inspect it in Xcode or run
  `xcrun xcresulttool get test-results summary --path /tmp/ios-unit-tests.xcresult`.
  Failed CI UI runs retain `ios-ui-test-results` for 14 days; download it with
  `--name ios-ui-test-results --dir /tmp/ios-ui-tests.xcresult` instead.
- `rake ios:testflight` — archive the iOS app and upload it to TestFlight (see
  the task's comments in the `Rakefile` for the required App Store Connect key).
- `rake checks` — run the Ruby and web linting and formatting checks.

The `changes` component snapshots the database for diffing over time:

- `rake changes:archive` / `rake changes:diff` / `rake changes:rewind` —
  snapshot the database for a given day, diff the two newest snapshots, and
  list this year's most-played tracks.
- `rake changes:spec` — test the archive and CLI diff using JSON fixtures,
  temporary directories, and isolated schemas in `warehouse_test`, with the
  same database credentials as the server specs.

Daily track snapshots retain complete Lyrics and Comments, including line breaks.
Diffs show `lyrics: changed` without lyric text; Comments use the usual metadata
diff output. A text field absent from either snapshot is unknown and is skipped
for that comparison, so older archives remain comparable without assuming empty
text.

Archive and diff commands accept `CHANGES_DIRECTORY` to use a separate directory
containing `tracks/` and `playlists/`. Archive also accepts `CHANGES_DATABASE_URL`
to select an isolated database; by default it reads the local `warehouse` database
as user `warehouse`. Tests exercise both Rake commands with these overrides and
never read or replace production archives.
