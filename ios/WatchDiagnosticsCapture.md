# Paired watch diagnostic capture

Status: device measurements pending. The simulator cannot validate `WCSession.transferFile` delivery. Use a paired phone and watch with this build installed on both devices.

## Capture setup

1. Record phone/watch models and OS versions, library file codec and bitrate, app build, endpoint, and whether the watch uses the nearby phone, Wi-Fi, or cellular. Pick a playlist with at least five representative tracks, including an MP3 with a nonzero start offset. Mark which tracks and artwork are cached before each run.
2. In macOS Console, select each device and save its log separately. Filter the subsystem `com.jcaffrey.warehouse` and category `watch-diagnostics`. Export the filtered logs, keeping the device clocks synchronized. Events are one lowercase JSON object per log message; `date` is milliseconds since the Unix epoch. They contain no token, cookie, filename, URL, or error description. The `id` joins phone and watch transfer events; player IDs join each track's requested, started, stall, and recovery events. Match event names below without regard to letter case.
3. Start a run marker in the capture notes and play or prepare the same playlist under each condition below. Run at least three trials per condition. For each trial, record the user tap time and first audible sound time with a screen/audio recording. The `playbackStarted` event is the app's buffered, advancing media-clock proxy; compare it with audible sound on the physical watch.
4. For the optional-transfer comparison, first pause offline preparation, keep list artwork offscreen, and stream a cold queue. Then resume preparation and browse list artwork while repeating the same queue under the same network profile. Record both startup and every stall. Keep the next-item daemon lookahead enabled in both runs. This comparison is observational because queue and cache state can change; use matched uncached tracks or reinstall and reselect the same playlist between trials.
5. After each run, export both device logs and the results row. Do not attach unredacted network captures or authentication headers to a Beads issue.

## Device matrix

Run the playlist with the watch app open while cached audio plays; open with playback stopped during offline preparation; wrist down; Apple's Workout app frontmost while Warehouse audio continues; and the phone foreground, background, and locked. Repeat with nearby-phone network, watch Wi-Fi, and watch cellular where available. Include airplane-mode playback of an already prepared playlist, phone reconnection, watch app relaunch while a phone transfer is outstanding, low storage, and five consecutive track transitions. For low storage, stop before risking the device's system reserve and record the reported free bytes.

For phone transfers, compare accepted requests against `phoneDelivered` or `phoneFailed` on the watch by ID and `fileType`, including those finishing after two seconds for artwork and thirty seconds for music. `phoneTimedOut` followed by `httpStarted` is a fallback, not proof that the phone transfer failed. `phoneMiss` identifies absence on the phone; `requestRejected` includes an explicit `reply` reason for authorization, queue, connectivity, or invalid requests; `storageFailure` identifies admission or commit failure. `httpStarted` to `httpDelivered` or `httpFailed` measures fallback latency. `playbackRequested` to `playbackStarted` measures the app's startup proxy; `playbackBuffering` records initial waiting, and subsequent `playbackStalled` and `playbackRecovered` mark stalls. Compare the audio recording for actual startup. Event `bytes`, `throughput`, `bufferSeconds`, `waitingReason`, and route are populated when AVFoundation supplies them.

## Endpoint check

Using a test token in a private shell environment, request a representative music file with `Range: bytes=0-65535` and another range near its expected start offset. Record HTTP status, `Content-Range`, `Accept-Ranges`, `Content-Length`, time to first byte, redirects, final host, codec, and bitrate. Repeat through the deployed nginx/Funnel route and any direct route available. Expect a valid `206` and byte range for each partial response. Keep headers and token out of shared results. Compare actual endpoint behavior; `nginx.conf.example` is only a template.

## Results

| Run | Device / OS | Network | Watch / phone state | Cache hits / requests | Phone accepted / delivered; p50 / p95 latency; over 2s / 30s | Playback p50 / p95 audible startup | Stalls / 5 tracks | Classification / notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Pending | Pending paired device | Pending | Pending | Pending | Pending | Pending | Pending | No hardware capture in this session |

## Background download decision

Keep the current foreground preparation and direct AVPlayer streaming behavior while measuring actual transport limits. A watch background `URLSession` can persist download tasks across app closure, but delivery can be deferred until the app is active. A future adapter would need a stable session identifier, persisted task-to-file mapping, launch-time `getAllTasks` reconciliation, a delegate that moves received files to durable storage before completion, and WatchKit background task handling that calls the system completion after events are processed. It must share file admission and credential validation with the foreground path and never gate current or next-track playback. Do not enable it from this diagnostic change without device timing and lifecycle tests.

References: [Apple Watch Connectivity file transfer](https://developer.apple.com/documentation/watchconnectivity/wcsession/transferfile(_:metadata:)); [Apple watchOS background requests](https://developer.apple.com/documentation/watchos-apps/making-background-requests).
