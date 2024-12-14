import Grid from "@mui/material/Grid2";
import AuthWrapper from "./AuthWrapper";
import LibraryWrapper from "./LibraryWrapper";
import Controls from "./Controls";
import TrackDisplay from "./TrackDisplay";
import SearchBar from "./SearchBar";
import Playlists from "./Playlists";
import TrackTable from "./TrackTable";
import SettingsRecorder from "./SettingsRecorder";

function App() {
  return (
    <AuthWrapper>
      <LibraryWrapper>
        <Grid container>
          <Grid size={4}>
            <Controls />
          </Grid>
          <Grid size={4}>
            <TrackDisplay />
          </Grid>
          <Grid size={4}>
            <SearchBar />
          </Grid>
          <Grid size={2}>
            <Playlists />
          </Grid>
          <Grid size={2}>
            <TrackTable />
          </Grid>
        </Grid>
      </LibraryWrapper>
      <SettingsRecorder />
    </AuthWrapper>
  );
}

export default App;
