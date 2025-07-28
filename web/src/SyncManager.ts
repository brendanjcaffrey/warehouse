import axios, { isAxiosError } from "axios";
import {
  IsStartSyncMessage,
  IsTypedMessage,
  TypedMessage,
  ErrorMessage,
  LibraryMetadataMessage,
  SYNC_SUCCEEDED_TYPE,
  ERROR_TYPE,
  LIBRARY_METADATA_TYPE,
} from "./WorkerTypes";
import library, { Track, Playlist } from "./Library";
import {
  VersionResponse,
  LibraryResponse,
  Library,
  Name,
  SortName,
} from "./generated/messages";

enum LibraryStatus {
  NEEDS_UPDATE,
  HAVE_LATEST_VERSION,
  ERROR,
}

type LibraryNeedsUpdate = {
  status: LibraryStatus.NEEDS_UPDATE;
};

type LibraryHaveLatestVersion = {
  status: LibraryStatus.HAVE_LATEST_VERSION;
};

type LibraryError = {
  status: LibraryStatus.ERROR;
  error: string;
};

type LibraryStatusResponse =
  | LibraryNeedsUpdate
  | LibraryHaveLatestVersion
  | LibraryError;

export class SyncManager {
  private syncInProgress: boolean = false;

  public async startSync(
    authToken: string,
    updateTimeNs: number,
    browserOnline: boolean
  ) {
    // this happens because react runs all effects twice in development mode
    if (this.syncInProgress) {
      return;
    }
    this.syncInProgress = true;

    // check if we have the most update to date version of the library, if so don't sync
    const response = await this.fetchLibraryStatus(
      authToken,
      updateTimeNs,
      browserOnline
    );
    switch (response.status) {
      case LibraryStatus.NEEDS_UPDATE:
        await this.syncLibrary(authToken);
        break;
      case LibraryStatus.HAVE_LATEST_VERSION:
        postMessage({ type: SYNC_SUCCEEDED_TYPE } as TypedMessage);
        this.syncInProgress = false;
        break;
      case LibraryStatus.ERROR:
        postMessage({
          type: ERROR_TYPE,
          error: response.error,
        } as ErrorMessage);
        this.syncInProgress = false;
        break;
    }
  }

  private async fetchLibraryStatus(
    authToken: string,
    updateTimeNs: number,
    browserOnline: boolean
  ): Promise<LibraryStatusResponse> {
    if (updateTimeNs === 0) {
      return { status: LibraryStatus.NEEDS_UPDATE };
    }

    try {
      const { data } = await axios.get("/api/version", {
        responseType: "arraybuffer",
        headers: { Authorization: `Bearer ${authToken}` },
      });
      const msg = VersionResponse.deserialize(data);
      if (msg.response === "error") {
        throw new Error(msg.error);
      }

      if (msg.updateTimeNs === updateTimeNs) {
        return { status: LibraryStatus.HAVE_LATEST_VERSION };
      } else {
        return { status: LibraryStatus.NEEDS_UPDATE };
      }
    } catch (error) {
      console.error(error);
      // if we're offline, pretend we have the latest version
      if (
        isAxiosError(error) &&
        (!browserOnline || error.code === "ERR_NETWORK")
      ) {
        return { status: LibraryStatus.HAVE_LATEST_VERSION };
      } else if (error instanceof Error) {
        return { status: LibraryStatus.ERROR, error: error.message };
      } else {
        return { status: LibraryStatus.ERROR, error: "unknown error" };
      }
    }
  }

  private async syncLibrary(authToken: string) {
    try {
      const { data } = await axios.get("/api/library", {
        responseType: "arraybuffer",
        headers: { Authorization: `Bearer ${authToken}` },
      });
      const msg = LibraryResponse.deserialize(data);
      if (msg.response === "error") {
        throw new Error(msg.error);
      }

      await this.processSyncResponse(msg.library);
      postMessage({ type: SYNC_SUCCEEDED_TYPE } as TypedMessage);
    } catch (error) {
      console.error(error);
      if (error instanceof Error) {
        postMessage({ type: ERROR_TYPE, error: error.message } as ErrorMessage);
      } else {
        postMessage({
          type: ERROR_TYPE,
          error: "unknown error",
        } as ErrorMessage);
      }
    } finally {
      this.syncInProgress = false;
    }
  }

  private static getName(value: Name | SortName | undefined): string {
    return value?.name ?? "";
  }

  private static getSortName(value: SortName | undefined): string {
    if (
      !value ||
      value.sortName === undefined ||
      value.sortName === value.name
    ) {
      return "";
    }
    return value.sortName;
  }

  private async processSyncResponse(msg: Library) {
    library().clear();

    postMessage({
      type: LIBRARY_METADATA_TYPE,
      trackUserChanges: msg.trackUserChanges,
      totalFileSize: msg.totalFileSize,
      updateTimeNs: msg.updateTimeNs,
    } as LibraryMetadataMessage);

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
        trackNumber: track.trackNumber,
        discNumber: track.discNumber,
        playCount: track.playCount,
        rating: track.rating,
        ext: track.ext,
        fileMd5: track.fileMd5,
        artwork: track.artworkFilename === "" ? null : track.artworkFilename,
        playlistIds: track.playlistIds,
      };
      await library().putTrack(dto);
    }

    const parentPlaylistId = new Map<string, string | null>();
    const childPlaylistIds = new Map<string, string[]>();
    for (const playlist of msg.playlists) {
      parentPlaylistId.set(playlist.id, playlist.parentId);
      if (!childPlaylistIds.has(playlist.parentId)) {
        childPlaylistIds.set(playlist.parentId, []);
      }
      childPlaylistIds.get(playlist.parentId)!.push(playlist.id);
    }

    for (const playlist of msg.playlists) {
      const dto: Playlist = {
        id: playlist.id,
        name: playlist.name,
        parentId: playlist.parentId,
        isLibrary: playlist.isLibrary,
        trackIds: playlist.trackIds,
        parentPlaylistIds: this.gatherParentPlaylistIds(
          playlist.id,
          parentPlaylistId
        ),
        childPlaylistIds: this.gatherChildPlaylistIds(
          playlist.id,
          childPlaylistIds
        ),
      };
      await library().putPlaylist(dto);
    }
  }

  private gatherParentPlaylistIds(
    playlistId: string,
    parentPlaylistId: Map<string, string | null>,
    out: string[] = []
  ): string[] {
    const parentId = parentPlaylistId.get(playlistId);
    if (parentId) {
      out.push(parentId);
      return this.gatherParentPlaylistIds(parentId, parentPlaylistId, out);
    }
    return out;
  }

  private gatherChildPlaylistIds(
    playlistId: string,
    childPlaylistIds: Map<string, string[]>
  ): string[] {
    const childIds = childPlaylistIds.get(playlistId);
    if (!childIds) {
      return [];
    }
    const out: string[] = [];
    for (const childId of childIds) {
      out.push(childId);
      out.push(...this.gatherChildPlaylistIds(childId, childPlaylistIds));
    }
    return out;
  }
}

const syncManager = new SyncManager();

onmessage = (m: MessageEvent) => {
  const { data } = m;
  if (!IsTypedMessage(data)) {
    return;
  }

  if (IsStartSyncMessage(data)) {
    syncManager.startSync(
      data.authToken,
      data.updateTimeNs,
      data.browserOnline
    );
  }
};
