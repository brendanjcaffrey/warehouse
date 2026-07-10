import { useParams } from "react-router-dom";
import Placeholder from "./Placeholder";

function AlbumView() {
  const { id } = useParams();
  return <Placeholder title="album">tracks for album {id}</Placeholder>;
}

export default AlbumView;
