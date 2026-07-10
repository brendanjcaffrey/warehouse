import Placeholder from "./Placeholder";

interface TrackListProps {
  // when omitted the whole library is shown, otherwise just the playlist's tracks
  playlistId?: string;
}

// placeholder tracklist shared by the songs and playlist views until the real
// virtualized list is built
function TrackList({ playlistId }: TrackListProps) {
  return (
    <Placeholder title="tracks">
      {playlistId
        ? `the tracklist for playlist ${playlistId} will live here`
        : "the songs tracklist will live here"}
    </Placeholder>
  );
}

export default TrackList;
