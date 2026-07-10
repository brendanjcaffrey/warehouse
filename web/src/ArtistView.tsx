import { useParams } from "react-router-dom";
import Placeholder from "./Placeholder";

function ArtistView() {
  const { id } = useParams();
  return <Placeholder title="artist">tracks for artist {id}</Placeholder>;
}

export default ArtistView;
