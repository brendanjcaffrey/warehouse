import { useParams } from "react-router-dom";
import TrackList from "./TrackList";

function PlaylistView() {
  const { id } = useParams();
  return <TrackList key={id} playlistId={id} />;
}

export default PlaylistView;
