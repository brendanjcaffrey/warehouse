import axios from "axios";
import {
  isStartSyncMessage,
  isTypedMessage,
  SYNC_SUCCEEDED_TYPE,
  ERROR_TYPE,
} from "./WorkerTypes";
import library, { Track, Playlist } from "./Library";
import { LibraryResponse, Library, Name, SortName } from "./generated/messages";

class SyncManager {
  private syncInProgress: boolean = false;

  public startSync(authToken: string) {
    // this happens because react runs all effects twice in development mode
    if (this.syncInProgress) {
      console.log("sync is already in progress, ignoring startSync request");
      return;
    }

    this.syncInProgress = true;
    console.log("starting sync...");

    axios
      .get("/api/library", {
        responseType: "arraybuffer",
        headers: { Authorization: `Bearer ${authToken}` },
      })
      .then((response) => {
        const { data } = response;
        const msg = LibraryResponse.deserialize(data);
        if (msg.response === "error") {
          throw new Error(msg.error);
        }

        this.processSyncResponse(msg.library)
          .then(() => {
            postMessage({ type: SYNC_SUCCEEDED_TYPE });
          })
          .catch((error) => {
            console.error(error);
            postMessage({ type: ERROR_TYPE, error: error.message });
          });
      })
      .catch((error) => {
        console.error(error);
        postMessage({ type: ERROR_TYPE, error: error.message });
      })
      .finally(() => {
        this.syncInProgress = false;
      });
  }

  private static getName(value: Name | SortName | undefined): string {
    return value?.name ?? "";
  }

  private static getSortName(value: SortName | undefined): string {
    if (!value) {
      return "";
    }
    return value.sortName || value.name;
  }

  private async processSyncResponse(msg: Library) {
    console.log("processing sync response", msg);
    library().clear();

    for (const track of msg.tracks) {
      const artist = msg.artists.get(track.artistId);
      const albumArtist = msg.artists.get(track.albumArtistId);
      const album = msg.albums.get(track.albumId);
      const genre = msg.genres.get(track.genreId);
      const dto: Track = {
        id: track.id,
        name: track.name,
        sortName: track.sortName,
        artistName: SyncManager.getName(artist),
        artistSortName: SyncManager.getSortName(artist),
        albumArtistName: SyncManager.getName(albumArtist),
        albumArtistSortName: SyncManager.getSortName(albumArtist),
        albumName: SyncManager.getName(album),
        albumSortName: SyncManager.getSortName(album),
        genre: SyncManager.getName(genre),
        year: track.year,
        duration: track.duration,
        start: track.start,
        finish: track.finish,
        trackNum: track.trackNumber,
        discNum: track.discNumber,
        playCount: track.playCount,
        rating: track.rating,
        ext: track.ext,
      };
      await library().putTrack(dto);
    }

    for (const playlist of msg.playlists) {
      const dto: Playlist = {
        id: playlist.id,
        name: playlist.name,
        parentId: playlist.parentId,
        isLibrary: playlist.isLibrary,
        trackIds: playlist.trackIds,
      };
      await library().putPlaylist(dto);
    }
  }
}

const syncManager = new SyncManager();

onmessage = (m: MessageEvent) => {
  const { data } = m;
  if (!isTypedMessage(data)) {
    return;
  }

  if (isStartSyncMessage(data)) {
    syncManager.startSync(data.authToken);
  }
};
