import { Track } from "./Library";

export interface DiscGroup {
  discNumber: number;
  tracks: Track[];
}

export interface Album {
  name: string;
  isUnknown: boolean;
  year: number;
  genre: string;
  tracks: Track[];
  discs: DiscGroup[];
  hasMultipleDiscs: boolean;
  songCount: number;
  totalDuration: number;
  // a track carrying artwork if any, used to load the album's cover
  artworkTrack: Track;
}

const byDiscThenTrack = (a: Track, b: Track): number =>
  a.discNumber - b.discNumber || a.trackNumber - b.trackNumber;

// groups an artist's tracks into albums, newest year first, with any blank-named
// "unknown" album pinned to the bottom. tracks within an album are ordered by
// disc then track number and split into disc sections when more than one disc.
export function buildAlbums(tracks: Track[]): Album[] {
  const byName = new Map<string, Track[]>();
  for (const track of tracks) {
    const group = byName.get(track.albumName);
    if (group) {
      group.push(track);
    } else {
      byName.set(track.albumName, [track]);
    }
  }

  const albums: Album[] = [];
  for (const [name, albumTracks] of byName) {
    const sorted = [...albumTracks].sort(byDiscThenTrack);
    const discNumbers = [...new Set(sorted.map((t) => t.discNumber))];
    const discs: DiscGroup[] = discNumbers.map((discNumber) => ({
      discNumber,
      tracks: sorted.filter((t) => t.discNumber === discNumber),
    }));

    albums.push({
      name,
      isUnknown: name === "",
      year: Math.max(0, ...sorted.map((t) => t.year)),
      genre: sorted.find((t) => t.genre)?.genre ?? "",
      tracks: sorted,
      discs,
      hasMultipleDiscs: discNumbers.length > 1,
      songCount: sorted.length,
      totalDuration: sorted.reduce((sum, t) => sum + t.duration, 0),
      artworkTrack: sorted.find((t) => t.artworkFilename) ?? sorted[0],
    });
  }

  albums.sort((a, b) => {
    if (a.isUnknown !== b.isUnknown) {
      return a.isUnknown ? 1 : -1;
    }
    return b.year - a.year || a.name.localeCompare(b.name);
  });

  return albums;
}

// a "x songs, y minutes" summary line, with the seconds rounded to whole minutes
export function formatAlbumSummary(
  songCount: number,
  totalDuration: number
): string {
  const minutes = Math.round(totalDuration / 60);
  const songLabel = songCount === 1 ? "song" : "songs";
  const minuteLabel = minutes === 1 ? "minute" : "minutes";
  return `${songCount} ${songLabel}, ${minutes} ${minuteLabel}`;
}
