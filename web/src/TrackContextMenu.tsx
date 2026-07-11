import { ReactNode, useCallback, useEffect, useRef, useState } from "react";
import {
  CaretRightFill,
  Download,
  MusicNoteList,
  PencilSquare,
  PlayFill,
  SkipForwardFill,
} from "react-bootstrap-icons";
import library, { Playlist, Track } from "./Library";
import { usePlaylists } from "./usePlaylists";
import { trackPlaylistOptions } from "./TrackMenu";

interface Position {
  x: number;
  y: number;
}

// a plain row in the context menu; the actions do nothing yet, they just close
function MenuItem({
  icon,
  onClick,
  children,
}: {
  icon: ReactNode;
  onClick: () => void;
  children: ReactNode;
}) {
  return (
    <button
      type="button"
      role="menuitem"
      onClick={onClick}
      className="dropdown-item d-flex align-items-center gap-2"
    >
      <span className="flex-shrink-0 d-inline-flex">{icon}</span>
      {children}
    </button>
  );
}

// the right-click menu for a track, shared by the songs, playlist, artist and
// album views. edit only appears when the library allows track changes, and
// "show in playlist" flies out into the playlists the track is in
function TrackContextMenu({
  position,
  track,
  playlists,
  currentPlaylistId,
  onClose,
}: {
  position: Position;
  track: Track;
  playlists: Playlist[];
  currentPlaylistId?: string;
  onClose: () => void;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const [submenuOpen, setSubmenuOpen] = useState(false);

  useEffect(() => {
    const onPointerDown = (event: MouseEvent) => {
      if (ref.current && !ref.current.contains(event.target as Node)) {
        onClose();
      }
    };
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        onClose();
      }
    };
    window.addEventListener("mousedown", onPointerDown);
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("mousedown", onPointerDown);
      window.removeEventListener("keydown", onKey);
    };
  }, [onClose]);

  const canEdit = library().getTrackUserChanges();
  const options = trackPlaylistOptions(track, playlists, currentPlaylistId);

  return (
    <div
      ref={ref}
      role="menu"
      className="dropdown-menu show shadow-sm"
      style={{
        position: "fixed",
        top: position.y,
        left: position.x,
        zIndex: 1080,
        minWidth: 200,
      }}
    >
      <MenuItem icon={<PlayFill size={15} />} onClick={onClose}>
        Play
      </MenuItem>
      <MenuItem icon={<SkipForwardFill size={15} />} onClick={onClose}>
        Play Next
      </MenuItem>
      <MenuItem icon={<Download size={15} />} onClick={onClose}>
        Download
      </MenuItem>
      {canEdit && (
        <MenuItem icon={<PencilSquare size={15} />} onClick={onClose}>
          Edit
        </MenuItem>
      )}
      <div className="dropdown-divider" />
      <div
        className="position-relative"
        onMouseEnter={() => setSubmenuOpen(true)}
        onMouseLeave={() => setSubmenuOpen(false)}
      >
        <button
          type="button"
          role="menuitem"
          aria-haspopup="menu"
          aria-expanded={submenuOpen}
          className="dropdown-item d-flex align-items-center gap-2"
        >
          <span className="flex-shrink-0 d-inline-flex">
            <MusicNoteList size={15} />
          </span>
          Show in Playlist
          <CaretRightFill size={10} className="ms-auto flex-shrink-0" />
        </button>
        {submenuOpen && (
          <div
            role="menu"
            className="dropdown-menu show shadow-sm"
            style={{
              position: "absolute",
              top: 0,
              left: "100%",
              zIndex: 1081,
              minWidth: 180,
              maxHeight: 320,
              overflowY: "auto",
            }}
          >
            {options.length === 0 ? (
              <span className="dropdown-item disabled text-secondary">
                {currentPlaylistId
                  ? "not in any other playlists"
                  : "not in any playlists"}
              </span>
            ) : (
              options.map((option) => (
                <button
                  key={option.id}
                  type="button"
                  role="menuitem"
                  onClick={onClose}
                  className="dropdown-item text-truncate"
                >
                  {option.name}
                </button>
              ))
            )}
          </div>
        )}
      </div>
    </div>
  );
}

// wires a track context menu into a view: openMenu on a row's onContextMenu, and
// render the returned element once. playlists load once for the view so the
// submenu is ready without a fetch per right-click
export function useTrackContextMenu(currentPlaylistId?: string) {
  const playlists = usePlaylists();
  const [state, setState] = useState<{
    track: Track;
    position: Position;
  } | null>(null);

  const openMenu = useCallback((event: React.MouseEvent, track: Track) => {
    event.preventDefault();
    setState({ track, position: { x: event.clientX, y: event.clientY } });
  }, []);

  const element = state ? (
    <TrackContextMenu
      position={state.position}
      track={state.track}
      playlists={playlists}
      currentPlaylistId={currentPlaylistId}
      onClose={() => setState(null)}
    />
  ) : null;

  return { openMenu, element };
}

export default TrackContextMenu;
