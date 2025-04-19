import { Box } from "@mui/material";
import Playlists from "./Playlists";
import LogOutButton from "./LogOutButton";

function Sidebar() {
  const logoutHeight = "36.5px";
  const playlistsHeight = `calc(100% - ${logoutHeight})`;

  return (
    <>
      <Playlists height={playlistsHeight} />
      <Box sx={{ height: logoutHeight }}>
        <LogOutButton sx={{ width: "100%" }} />
      </Box>
    </>
  );
}

export default Sidebar;
