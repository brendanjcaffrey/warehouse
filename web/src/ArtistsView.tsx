import { useCallback, useMemo, useRef, useState } from "react";
import { useAtomValue } from "jotai";
import { FixedSizeList, ListChildComponentProps } from "react-window";
import AutoSizer from "react-virtualized-auto-sizer";
import { artistListWidthAtom, ClampSidebarWidth } from "./Settings";
import { searchAtom } from "./State";
import { useRevealListSelection } from "./Reveal";
import { useResizableWidth } from "./useResizableWidth";
import { useTypeToSearch } from "./useTypeToSearch";
import { useTracks } from "./useTracks";
import { buildArtistList, filterArtists } from "./Artists";
import ArtistDetail from "./ArtistDetail";
import { rowClass } from "./Sidebar";

// tall enough for one py-2 row so the virtualized list can position rows by index
const ROW_HEIGHT = 40;

function ArtistsView() {
  const tracks = useTracks();
  const search = useAtomValue(searchAtom);
  const allArtists = useMemo(() => buildArtistList(tracks), [tracks]);
  const artists = useMemo(
    () => filterArtists(allArtists, search),
    [allArtists, search]
  );
  const [selected, setSelected] = useState<string | null>(null);
  const selectedTracks = useMemo(
    () =>
      selected ? tracks.filter((track) => track.artistName === selected) : [],
    [tracks, selected]
  );
  const { displayWidth, containerRef, startResize } = useResizableWidth(
    artistListWidthAtom,
    ClampSidebarWidth
  );
  const listRef = useRef<FixedSizeList>(null);

  const artistNames = useMemo(
    () => artists.map((artist) => artist.name),
    [artists]
  );
  const scrollToIndex = useCallback(
    (index: number) => listRef.current?.scrollToItem(index, "smart"),
    []
  );
  // a "go to artist" selects the artist and scrolls the list to it; the mounted
  // ArtistDetail then reveals the track and clears the request
  useRevealListSelection(
    "artists",
    artistNames,
    selected,
    setSelected,
    scrollToIndex
  );

  const selectIndex = useCallback(
    (index: number) => {
      const artist = artists[index];
      if (!artist) {
        return;
      }
      setSelected(artist.name);
      listRef.current?.scrollToItem(index, "smart");
    },
    [artists]
  );

  // artists are sorted by sort name, so type-to-search matches against it
  const searchNames = useMemo(
    () => artists.map((artist) => artist.sortName),
    [artists]
  );
  const handleTypeSearch = useTypeToSearch(searchNames, selectIndex);

  const handleKeyDown = useCallback(
    (event: React.KeyboardEvent) => {
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault();
        const current = artists.findIndex((artist) => artist.name === selected);
        const delta = event.key === "ArrowDown" ? 1 : -1;
        selectIndex(current === -1 ? 0 : current + delta);
        return;
      }
      if (handleTypeSearch(event)) {
        event.preventDefault();
      }
    },
    [artists, selected, selectIndex, handleTypeSearch]
  );

  // react-window only mounts the visible rows, so a drag or selection change
  // reconciles ~a screenful of rows rather than every artist
  const Row = useCallback(
    ({ index, style }: ListChildComponentProps) => {
      const artist = artists[index];
      const isSelected = artist.name === selected;
      return (
        <div
          role="option"
          aria-selected={isSelected}
          onClick={() => selectIndex(index)}
          className={rowClass(isSelected)}
          style={{
            ...style,
            paddingLeft: 12,
            paddingRight: 12,
            cursor: "pointer",
          }}
        >
          <span className="text-truncate">{artist.name}</span>
        </div>
      );
    },
    [artists, selected, selectIndex]
  );

  return (
    <div className="d-flex h-100 user-select-none">
      <div
        ref={containerRef}
        className="position-relative h-100 border-end"
        style={{ width: displayWidth, minWidth: displayWidth, flexShrink: 0 }}
      >
        <div className="d-flex flex-column h-100 bg-body-tertiary">
          <div
            className="flex-grow-1"
            style={{ minHeight: 0 }}
            role="listbox"
            aria-label="artists"
            tabIndex={0}
            onKeyDown={handleKeyDown}
          >
            <AutoSizer>
              {({ height, width }) => (
                <FixedSizeList
                  ref={listRef}
                  height={height}
                  width={width}
                  itemCount={artists.length}
                  itemSize={ROW_HEIGHT}
                >
                  {Row}
                </FixedSizeList>
              )}
            </AutoSizer>
          </div>
        </div>
        <div
          className="sidebar-resize-handle"
          onMouseDown={startResize}
          role="separator"
          aria-orientation="vertical"
        />
      </div>
      <div className="flex-grow-1" style={{ minWidth: 0 }}>
        {selected && (
          <ArtistDetail
            key={selected}
            name={selected}
            tracks={selectedTracks}
          />
        )}
      </div>
    </div>
  );
}

export default ArtistsView;
