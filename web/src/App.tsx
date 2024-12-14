import AuthWrapper from "./AuthWrapper";
import LibraryWrapper from "./LibraryWrapper";

function App() {
  return (
    <AuthWrapper>
      <LibraryWrapper>
        <h1>Music Streamer</h1>
      </LibraryWrapper>
    </AuthWrapper>
  );
}

export default App;
