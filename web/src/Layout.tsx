import { Routes, Route, Navigate } from "react-router-dom";
import Controls from "./Controls";
import NowPlaying from "./NowPlaying";
import SearchBar from "./SearchBar";
import Sidebar from "./Sidebar";
import SongsView from "./SongsView";
import ArtistsView from "./ArtistsView";
import ArtistView from "./ArtistView";
import AlbumsView from "./AlbumsView";
import AlbumView from "./AlbumView";
import PlaylistView from "./PlaylistView";

function Layout() {
  const topBarStyle = {
    height: "52px",
    flex: "1 1 0",
    minWidth: 0,
  };

  return (
    <div className="d-flex flex-column vh-100">
      <div className="d-flex flex-shrink-0 border-bottom">
        <div className="d-flex align-items-center" style={topBarStyle}>
          <Controls />
        </div>
        <div className="d-flex align-items-center" style={topBarStyle}>
          <NowPlaying />
        </div>
        <div className="d-flex align-items-center" style={topBarStyle}>
          <SearchBar />
        </div>
      </div>
      <div className="d-flex flex-grow-1" style={{ minHeight: 0 }}>
        <Sidebar />
        <main className="flex-grow-1 overflow-auto">
          <Routes>
            <Route path="/" element={<Navigate to="/songs" replace />} />
            <Route path="/songs" element={<SongsView />} />
            <Route path="/artists" element={<ArtistsView />} />
            <Route path="/artists/:id" element={<ArtistView />} />
            <Route path="/albums" element={<AlbumsView />} />
            <Route path="/albums/:id" element={<AlbumView />} />
            <Route path="/playlists/:id" element={<PlaylistView />} />
            <Route path="*" element={<Navigate to="/songs" replace />} />
          </Routes>
        </main>
      </div>
    </div>
  );
}

export default Layout;
