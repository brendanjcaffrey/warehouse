import Playlists from "./Playlists";
import Artwork from "./Artwork";
import LogOut from "./LogOut";

function Sidebar() {
  const logoutHeight = "36.5px";
  const playlistsHeight = `calc(100% - ${logoutHeight})`;

  return (
    <>
      <Playlists height={playlistsHeight} />
      <Artwork />
      <LogOut height={logoutHeight} />
    </>
  );
}

export default Sidebar;
