import Grid from "@mui/material/Grid2";
import { SxProps } from "@mui/system";
import AuthWrapper from "./AuthWrapper";
import LibraryWrapper from "./LibraryWrapper";
import Controls from "./Controls";
import TrackDisplay from "./TrackDisplay";
import SearchBar from "./SearchBar";
import Sidebar from "./Sidebar";
import TrackTable from "./TrackTable";
import SettingsRecorder from "./SettingsRecorder";

function App() {
  const topBarSx: SxProps = { height: "52px" };
  const bodySx: SxProps = {
    overflowY: "auto",
    height: `calc(100% - ${topBarSx.height})`,
  };

  return (
    <AuthWrapper>
      <LibraryWrapper>
        <Grid container sx={{ height: "100vh" }}>
          <Grid size={4} sx={topBarSx}>
            <Controls />
          </Grid>
          <Grid size={4} sx={topBarSx}>
            <TrackDisplay />
          </Grid>
          <Grid size={4} sx={topBarSx}>
            <SearchBar />
          </Grid>
          <Grid size={2} sx={bodySx}>
            <Sidebar />
          </Grid>
          <Grid size={10} sx={bodySx}>
            <TrackTable />
          </Grid>
        </Grid>
      </LibraryWrapper>
      <SettingsRecorder />
    </AuthWrapper>
  );
}

export default App;
