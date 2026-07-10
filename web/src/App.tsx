import { Provider as JotaiProvider } from "jotai";
import { store } from "./State";
import AuthWrapper from "./AuthWrapper";
import LibraryWrapper from "./LibraryWrapper";
import Controls from "./Controls";
import NowPlaying from "./NowPlaying";
import SearchBar from "./SearchBar";
import Audio from "./Audio";
import SettingsRecorder from "./SettingsRecorder";
import "./index.css";
import { BackgroundWrapper } from "./BackgroundWrapper";

function App() {
  const topBarStyle = {
    height: "52px",
    flex: "1 1 0",
    minWidth: 0,
  };

  return (
    <JotaiProvider store={store}>
      <BackgroundWrapper>
        <AuthWrapper>
          <LibraryWrapper>
            <div className="d-flex vh-100">
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
          </LibraryWrapper>
          <Audio />
          <SettingsRecorder />
        </AuthWrapper>
      </BackgroundWrapper>
    </JotaiProvider>
  );
}

export default App;
