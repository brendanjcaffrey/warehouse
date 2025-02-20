import Grid from "@mui/material/Grid2";
import { SxProps, createTheme, ThemeProvider } from "@mui/material";
import { Provider as JotaiProvider } from "jotai";
import { store } from "./State";
import { SnackbarProvider } from "notistack";
import AuthWrapper from "./AuthWrapper";
import LibraryWrapper from "./LibraryWrapper";
import Controls from "./Controls";
import NowPlaying from "./NowPlaying";
import SearchBar from "./SearchBar";
import Sidebar from "./Sidebar";
import TrackTable from "./TrackTable";
import Audio from "./Audio";
import SettingsRecorder from "./SettingsRecorder";
import { titleGrey, defaultGrey } from "./Colors";
import "./index.css";

const theme = createTheme({
  palette: {
    info: {
      main: titleGrey,
    },
    primary: {
      main: defaultGrey,
    },
  },
});

function App() {
  const topBarSx: SxProps = { height: "52px" };
  const bodySx: SxProps = { height: `calc(100% - ${topBarSx.height})` };

  return (
    <JotaiProvider store={store}>
      <ThemeProvider theme={theme}>
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
                <Sidebar />
              </Grid>
              <Grid size={10} sx={bodySx}>
                <TrackTable />
              </Grid>
            </Grid>
          </LibraryWrapper>
          <Audio />
          <SettingsRecorder />
        </AuthWrapper>
      </ThemeProvider>
    </JotaiProvider>
  );
}

export default App;
