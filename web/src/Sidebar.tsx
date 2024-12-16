import Playlists from "./Playlists";
import LogOut from "./LogOut";

function Sidebar() {
  const logoutHeight = "36.5px";
  const playlistsHeight = `calc(100% - ${logoutHeight})`;

  return (
    <>
      <Playlists height={playlistsHeight} />
      <LogOut height={logoutHeight} />
    </>
  );
}

export default Sidebar;
