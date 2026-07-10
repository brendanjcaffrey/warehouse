import { Provider as JotaiProvider } from "jotai";
import { HashRouter } from "react-router-dom";
import { store } from "./State";
import AuthWrapper from "./AuthWrapper";
import LibraryWrapper from "./LibraryWrapper";
import Layout from "./Layout";
import Audio from "./Audio";
import SettingsEffects from "./SettingsEffects";
import "./index.css";
import { BackgroundWrapper } from "./BackgroundWrapper";

function App() {
  return (
    <JotaiProvider store={store}>
      <BackgroundWrapper>
        <AuthWrapper>
          <HashRouter>
            <LibraryWrapper>
              <Layout />
            </LibraryWrapper>
          </HashRouter>
          <Audio />
          <SettingsEffects />
        </AuthWrapper>
      </BackgroundWrapper>
    </JotaiProvider>
  );
}

export default App;
