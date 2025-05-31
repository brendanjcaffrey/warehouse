import Grid from "@mui/material/Grid";
import { SxProps, createTheme, ThemeProvider } from "@mui/material";
import { Provider as JotaiProvider } from "jotai";
import { store } from "./State";
import { SnackbarProvider } from "notistack";
import AuthWrapper from "./AuthWrapper";
import LibraryWrapper from "./LibraryWrapper";
import Controls from "./Controls";
import NowPlaying from "./NowPlaying";
import SearchBar from "./SearchBar";
import Playlists from "./Playlists";
import TrackTable from "./TrackTable";
import Audio from "./Audio";
import SettingsRecorder from "./SettingsRecorder";
import "./index.css";
import { BackgroundWrapper } from "./BackgroundWrapper";

const theme = createTheme({
  colorSchemes: {
    dark: true,
  },
});

function App() {
  const topBarSx: SxProps = { height: "52px" };
  const bodySx: SxProps = { height: `calc(100% - ${topBarSx.height})` };

  return (
    <JotaiProvider store={store}>
      <ThemeProvider theme={theme}>
        <BackgroundWrapper>
          <SnackbarProvider maxSnack={3} />
          <AuthWrapper>
            <LibraryWrapper>
              <Grid container sx={{ height: "100vh" }}>
                <Grid size={4} sx={topBarSx}>
                  <Controls />
                </Grid>
                <Grid size={4} sx={topBarSx}>
                  <NowPlaying />
                </Grid>
                <Grid size={4} sx={topBarSx}>
                  <SearchBar />
                </Grid>
                <Grid size={2} sx={bodySx}>
                  <Playlists />
                </Grid>
                <Grid size={10} sx={bodySx}>
                  <TrackTable />
                </Grid>
              </Grid>
            </LibraryWrapper>
            <Audio />
            <SettingsRecorder />
          </AuthWrapper>
        </BackgroundWrapper>
      </ThemeProvider>
    </JotaiProvider>
  );
}

export default App;
