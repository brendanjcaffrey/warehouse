import { useCallback, useMemo, useRef, useState } from "react";
import { useAtomValue } from "jotai";
import {
  FixedSizeList,
  ListChildComponentProps,
  ListOnItemsRenderedProps,
} from "react-window";
import AutoSizer from "react-virtualized-auto-sizer";
import { albumListWidthAtom, ClampSidebarWidth } from "./Settings";
import { searchAtom } from "./State";
import { FileRequestSource } from "./WorkerTypes";
import { useResizableWidth } from "./useResizableWidth";
import { useTypeToSearch } from "./useTypeToSearch";
import { useAlbumArtworkRequests } from "./useAlbumArtworkRequests";
import { useTracks } from "./useTracks";
import { buildAlbumList, filterAlbumList } from "./AlbumList";
import { AlbumArtwork } from "./AlbumSection";
import AlbumDetail from "./AlbumDetail";
import { rowClass } from "./Sidebar";

// a cover thumbnail over two lines of text, tall enough for a py-2 row
const THUMBNAIL_SIZE = 40;
const ROW_HEIGHT = 56;

function AlbumsView() {
  const tracks = useTracks();
  const search = useAtomValue(searchAtom);
  const allAlbums = useMemo(() => buildAlbumList(tracks), [tracks]);
  const albums = useMemo(
    () => filterAlbumList(allAlbums, search),
    [allAlbums, search]
  );
  const [selectedKey, setSelectedKey] = useState<string | null>(null);
  const selectedAlbum = useMemo(
    () => albums.find((album) => album.key === selectedKey) ?? null,
    [albums, selectedKey]
  );
  const { displayWidth, containerRef, startResize } = useResizableWidth(
    albumListWidthAtom,
    ClampSidebarWidth
  );
  const listRef = useRef<FixedSizeList>(null);

  const selectIndex = useCallback(
    (index: number) => {
      const album = albums[index];
      if (!album) {
        return;
      }
      setSelectedKey(album.key);
      listRef.current?.scrollToItem(index, "smart");
    },
    [albums]
  );

  // albums are sorted by album sort name, so type-to-search matches against it
  const searchNames = useMemo(
    () => albums.map((album) => album.sortName),
    [albums]
  );
  const handleTypeSearch = useTypeToSearch(searchNames, selectIndex);

  const handleKeyDown = useCallback(
    (event: React.KeyboardEvent) => {
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault();
        const current = albums.findIndex((album) => album.key === selectedKey);
        const delta = event.key === "ArrowDown" ? 1 : -1;
        selectIndex(current === -1 ? 0 : current + delta);
        return;
      }
      if (handleTypeSearch(event)) {
        event.preventDefault();
      }
    },
    [albums, selectedKey, selectIndex, handleTypeSearch]
  );

  // only fetch covers for the rows near the viewport so a huge library doesn't
  // download every album's artwork up front
  const [range, setRange] = useState({ start: 0, stop: 0 });
  const handleItemsRendered = useCallback((props: ListOnItemsRenderedProps) => {
    setRange((prev) =>
      prev.start === props.overscanStartIndex &&
      prev.stop === props.overscanStopIndex
        ? prev
        : { start: props.overscanStartIndex, stop: props.overscanStopIndex }
    );
  }, []);
  const visibleAlbums = useMemo(
    () => albums.slice(range.start, range.stop + 1),
    [albums, range]
  );
  useAlbumArtworkRequests(visibleAlbums, FileRequestSource.ARTWORK_BROWSE_LIST);

  const Row = useCallback(
    ({ index, style }: ListChildComponentProps) => {
      const album = albums[index];
      const isSelected = album.key === selectedKey;
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
          <AlbumArtwork track={album.artworkTrack} size={THUMBNAIL_SIZE} />
          <div className="d-flex flex-column" style={{ minWidth: 0 }}>
            <span className="text-truncate">{album.name}</span>
            <span className="text-truncate text-secondary small">
              {album.artist}
            </span>
          </div>
        </div>
      );
    },
    [albums, selectedKey, selectIndex]
  );

  return (
    <div className="d-flex h-100">
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
            aria-label="albums"
            tabIndex={0}
            onKeyDown={handleKeyDown}
          >
            <AutoSizer>
              {({ height, width }) => (
                <FixedSizeList
                  ref={listRef}
                  height={height}
                  width={width}
                  itemCount={albums.length}
                  itemSize={ROW_HEIGHT}
                  onItemsRendered={handleItemsRendered}
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
        {selectedAlbum && (
          <AlbumDetail
            key={selectedAlbum.key}
            name={selectedAlbum.name}
            tracks={selectedAlbum.tracks}
          />
        )}
      </div>
    </div>
  );
}

export default AlbumsView;
