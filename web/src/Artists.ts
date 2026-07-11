import { Track } from "./Library";

export interface Artist {
  name: string;
  sortName: string;
}

// collapses the library's tracks into a distinct list of artists sorted by
// their sort name, falling back to the display name when a sort name is missing
export function buildArtistList(tracks: Track[]): Artist[] {
  const byName = new Map<string, Artist>();
  for (const track of tracks) {
    const name = track.artistName;
    if (!name || byName.has(name)) {
      continue;
    }
    byName.set(name, { name, sortName: track.artistSortName || name });
  }

  return Array.from(byName.values()).sort((a, b) =>
    a.sortName.localeCompare(b.sortName)
  );
}

// narrows the artist list to those whose name matches the search term, so the
// top-bar search filters the artists browser by artist name
export function filterArtists(artists: Artist[], query: string): Artist[] {
  const trimmed = query.trim().toLowerCase();
  if (!trimmed) {
    return artists;
  }
  return artists.filter(
    (artist) =>
      artist.name.toLowerCase().includes(trimmed) ||
      artist.sortName.toLowerCase().includes(trimmed)
  );
}
