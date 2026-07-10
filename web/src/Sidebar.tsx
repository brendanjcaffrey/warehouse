import { ReactNode, useMemo, useRef, useState } from "react";
import { useAtom } from "jotai";
import { NavLink } from "react-router-dom";
import { Collapse } from "react-bootstrap";
import {
  MusicNoteBeamed,
  PersonFill,
  Disc,
  FolderFill,
  MusicNoteList,
  CaretDownFill,
  CaretRightFill,
} from "react-bootstrap-icons";
import {
  openedFoldersAtom,
  sidebarWidthAtom,
  ClampSidebarWidth,
} from "./Settings";
import { usePlaylists } from "./usePlaylists";
import { buildPlaylistTree, PlaylistTreeNode } from "./PlaylistTree";

const rowClass = (isActive: boolean) =>
  `d-flex align-items-center gap-2 text-decoration-none py-2 text-body ${
    isActive ? "fw-semibold bg-body-secondary" : ""
  }`;

interface SidebarLinkProps {
  to: string;
  icon: ReactNode;
  label: string;
}

function SidebarLink({ to, icon, label }: SidebarLinkProps) {
  return (
    <NavLink
      to={to}
      className={({ isActive }) => rowClass(isActive)}
      style={{ paddingLeft: 12, paddingRight: 12 }}
    >
      {icon}
      <span className="text-truncate">{label}</span>
    </NavLink>
  );
}

interface PlaylistNodeProps {
  node: PlaylistTreeNode;
  depth: number;
}

function FolderNode({ node, depth }: PlaylistNodeProps) {
  const [openedFolders, setOpenedFolders] = useAtom(openedFoldersAtom);
  const open = openedFolders.has(node.playlist.id);
  const paddingLeft = 12 + depth * 16;

  const toggle = () =>
    setOpenedFolders((prev) => {
      const next = new Set(prev);
      if (next.has(node.playlist.id)) {
        next.delete(node.playlist.id);
      } else {
        next.add(node.playlist.id);
      }
      return next;
    });

  // the caret toggles open/close; the rest of the row navigates to the folder's
  // aggregated tracks, so stop the click from following the link
  const toggleFromCaret = (event: React.MouseEvent) => {
    event.preventDefault();
    event.stopPropagation();
    toggle();
  };

  return (
    <>
      <NavLink
        to={`/playlists/${node.playlist.id}`}
        className={({ isActive }) => rowClass(isActive)}
        style={{ paddingLeft, paddingRight: 12 }}
      >
        <span
          role="button"
          onClick={toggleFromCaret}
          className="d-inline-flex"
          style={{ cursor: "pointer" }}
        >
          {open ? <CaretDownFill size={10} /> : <CaretRightFill size={10} />}
        </span>
        <FolderFill size={14} />
        <span className="text-truncate">{node.playlist.name}</span>
      </NavLink>
      <Collapse in={open}>
        <div>
          {node.children.map((child) => (
            <PlaylistNode
              key={child.playlist.id}
              node={child}
              depth={depth + 1}
            />
          ))}
        </div>
      </Collapse>
    </>
  );
}

function PlaylistNode({ node, depth }: PlaylistNodeProps) {
  if (node.isFolder) {
    return <FolderNode node={node} depth={depth} />;
  }

  const paddingLeft = 12 + depth * 16;
  return (
    <NavLink
      to={`/playlists/${node.playlist.id}`}
      className={({ isActive }) => rowClass(isActive)}
      style={{ paddingLeft: paddingLeft + 18, paddingRight: 12 }}
    >
      <MusicNoteList size={14} />
      <span className="text-truncate">{node.playlist.name}</span>
    </NavLink>
  );
}

function Sidebar() {
  const playlists = usePlaylists();
  const tree = useMemo(() => buildPlaylistTree(playlists), [playlists]);

  const [width, setWidth] = useAtom(sidebarWidthAtom);
  // tracks the width live during a drag so we only persist to the atom on release
  const [dragWidth, setDragWidth] = useState<number | null>(null);
  const containerRef = useRef<HTMLDivElement>(null);

  const displayWidth = dragWidth ?? width;

  const startResize = (event: React.MouseEvent) => {
    event.preventDefault();
    const left = containerRef.current?.getBoundingClientRect().left ?? 0;
    let latest = width;

    const onMove = (moveEvent: MouseEvent) => {
      latest = ClampSidebarWidth(moveEvent.clientX - left);
      setDragWidth(latest);
    };
    const onUp = () => {
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", onUp);
      document.body.style.userSelect = "";
      document.body.style.cursor = "";
      setWidth(latest);
      setDragWidth(null);
    };

    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", onUp);
    document.body.style.userSelect = "none";
    document.body.style.cursor = "col-resize";
  };

  return (
    <div
      ref={containerRef}
      className="position-relative h-100 border-end"
      style={{ width: displayWidth, minWidth: displayWidth, flexShrink: 0 }}
    >
      <div
        className="d-flex flex-column h-100 bg-body-tertiary"
        style={{ overflowY: "auto" }}
      >
        <div className="py-2">
          <SidebarLink
            to="/songs"
            icon={<MusicNoteBeamed size={16} />}
            label="Songs"
          />
          <SidebarLink
            to="/artists"
            icon={<PersonFill size={16} />}
            label="Artists"
          />
          <SidebarLink to="/albums" icon={<Disc size={16} />} label="Albums" />
        </div>
        <hr className="my-1" />
        <div
          className="px-3 py-1 text-uppercase text-secondary"
          style={{ fontSize: 11, letterSpacing: 0.5 }}
        >
          playlists
        </div>
        <div className="pb-3">
          {tree.map((node) => (
            <PlaylistNode key={node.playlist.id} node={node} depth={0} />
          ))}
        </div>
      </div>
      <div
        className="sidebar-resize-handle"
        onMouseDown={startResize}
        role="separator"
        aria-orientation="vertical"
      />
    </div>
  );
}

export default Sidebar;
