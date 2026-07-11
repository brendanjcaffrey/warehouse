import { Track } from "./Library";

export interface AlbumListEntry {
  // stable unique key for the album-artist + album-name pair
  key: string;
  name: string;
  sortName: string;
  artist: string;
  // a track carrying artwork if any, used to load the album's cover
  artworkTrack: Track;
  tracks: Track[];
}

// the album's credited artist prefers the album artist, falling back to the
// track artist so the subtitle still reads sensibly
function albumArtist(track: Track): string {
  return track.albumArtistName || track.artistName;
}

// collapses the library's tracks into a distinct list of albums, one per
// album-artist and album-name pair, skipping tracks with a blank album name so
// no unknown album shows up. sorted by album sort name, then artist.
export function buildAlbumList(tracks: Track[]): AlbumListEntry[] {
  const byKey = new Map<string, Track[]>();
  for (const track of tracks) {
    if (!track.albumName) {
      continue;
    }
    const key = `${albumArtist(track)}\t${track.albumName}`;
    const group = byKey.get(key);
    if (group) {
      group.push(track);
    } else {
      byKey.set(key, [track]);
    }
  }

  const entries: AlbumListEntry[] = [];
  for (const [key, albumTracks] of byKey) {
    const first = albumTracks[0];
    entries.push({
      key,
      name: first.albumName,
      sortName: first.albumSortName || first.albumName,
      artist: albumArtist(first),
      artworkTrack: albumTracks.find((t) => t.artworkFilename) ?? first,
      tracks: albumTracks,
    });
  }

  entries.sort(
    (a, b) =>
      a.sortName.localeCompare(b.sortName) || a.artist.localeCompare(b.artist)
  );

  return entries;
}

// narrows the album list to those whose album name or artist matches the search
// term, so the top-bar search filters the albums browser
export function filterAlbumList(
  entries: AlbumListEntry[],
  query: string
): AlbumListEntry[] {
  const trimmed = query.trim().toLowerCase();
  if (!trimmed) {
    return entries;
  }
  return entries.filter(
    (entry) =>
      entry.name.toLowerCase().includes(trimmed) ||
      entry.sortName.toLowerCase().includes(trimmed) ||
      entry.artist.toLowerCase().includes(trimmed)
  );
}
