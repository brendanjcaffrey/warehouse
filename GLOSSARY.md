# Glossary

- **Saved library**: Track and playlist metadata successfully stored on the device. It may contain no songs and does not imply that music files are downloaded.
- **Local library readiness**: The result of loading the saved library for browsing. It is independent of remote refresh progress or connectivity.
- **Downloaded track**: A track whose music file is present on the device and can be played without a network connection.
- **Watch library**: The metadata, artwork and music stored on the watch for its selected playlists, supplied exclusively by the paired phone. Received content remains available while the phone is unavailable.
- **Watch playlist**: A playlist selected in the phone's Apple Watch settings whose current membership is automatically mirrored on the watch, requesting delivery and retention of its music. Music is removed when no selected watch playlist needs it; selection does not mean the music has arrived. _Avoid_: offline playlist, metadata-only selection.
- **Offline preparation**: Obtaining every missing music file in a watch playlist from the paired phone whenever the system permits, without requiring playback, charging or an open watch app. Ready means every selected track is present on the watch.
- **Storage full**: Watch preparation is waiting for enough free space to receive missing music, while downloaded music needed by selected playlists remains retained and playable. The selection stays pending and preparation resumes when space permits.
- **Downloaded-only playback**: A queue built from tracks already on disk, with music streaming, playback downloads, and now-playing artwork fetches disabled for that queue. This is the required playback policy for music played on the watch.
- **Watch file receipt**: A persisted acknowledgment that a file matching the desired watch library identity, revision, type, name and verified bytes is stored on the watch. A queued or system-completed transfer is not a receipt.
