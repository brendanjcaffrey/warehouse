import { Track } from "./Library";

export interface PlayingTrack {
  track: Track;
  playlistId: string;
  playlistOffset: number;
}

export interface PlaylistEntry {
  playlistId: string;
  playlistOffset: number;
}

export interface DisplayedTrack {
  trackId: string;
  playlistOffset: number;
}

export interface PlaylistTrack {
  playlistId: string;
  trackId: string;
  playlistOffset: number;
}
