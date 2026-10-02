# TestFlight watch diagnostics

The iPhone app embeds WarehouseWatch. Install the same TestFlight build on the paired phone and watch. Record both version/build numbers from the exported reports. Release upload is separate from diagnostic capture.

1. Save previous captures, then on the watch open **Diagnostics → Start New Capture**. The watch clears its events, cumulative totals and capture identity. Phone totals use their own capture window; save a baseline with **Settings → Apple Watch → Diagnostics → Save iPhone Capture**.
2. Select playlists on the phone and observe automatic delivery. Normal phone sync supplies missing phone music/artwork. Delivery remains eligible with apps closed or devices off charger, subject to system scheduling. Playback uses downloaded watch music.
3. On the watch refresh Diagnostics and tap **Send to iPhone**. The live message requires a reachable phone. Success means the phone saved paired watch and phone JSON reports with a shared `pairID`; failed sends leave the watch capture intact.
4. On the iPhone open the Apple Watch playlist/download settings and share both files in **Diagnostics**. Each send creates separate files; **Save iPhone Capture** also works without a reachable watch.
5. Record elapsed time, device state and count/byte deltas. Follow [the paired capture guide](WatchDiagnosticsCapture.md) for interpreting phases, unknown sizes, ring truncation and storage/retry state.

Exports include current selected inventory/queue state, build/device details, cumulative phase totals and the last 512 transitions. Totals and deduplication survive relaunch independently of the event ring. Receipt replay cannot count new verified bytes. Captures omit credentials, URLs, filenames, playlist names and error descriptions. Reports from older builds lack current-pipeline coverage; legacy zero delivery counters do not prove zero delivery. Physical remeasurement remains wh-8l1.4.
