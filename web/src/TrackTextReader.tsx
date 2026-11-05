import { useId, useState } from "react";
import { Button, Modal } from "react-bootstrap";
import library, { Track } from "./Library";
import EditTrackForm from "./EditTrackForm";

export type TrackTextField = "lyrics" | "comments";

// the caller owns whether the displayed track follows playback or stays pinned.
// editing captures its own track so playback can keep advancing independently.
function TrackTextReader({
  track,
  field,
  onClose,
}: {
  track: Track | undefined;
  field: TrackTextField;
  onClose: () => void;
}) {
  const titleId = useId();
  const [editTrack, setEditTrack] = useState<Track | null>(null);
  const title = field === "lyrics" ? "Lyrics" : "Comments";

  if (editTrack) {
    return (
      <EditTrackForm track={editTrack} onClose={() => setEditTrack(null)} />
    );
  }

  return (
    <Modal
      show
      centered
      scrollable
      aria-labelledby={titleId}
      onHide={onClose}
      onKeyDown={(event: React.KeyboardEvent) => event.stopPropagation()}
    >
      <Modal.Header closeButton>
        <div style={{ minWidth: 0 }}>
          <Modal.Title id={titleId}>{title}</Modal.Title>
          {track && (
            <div style={{ overflowWrap: "anywhere" }}>
              <div>{track.name}</div>
              <div className="text-secondary small">{track.artistName}</div>
            </div>
          )}
        </div>
      </Modal.Header>
      <Modal.Body
        key={track?.id}
        role="region"
        aria-label={`${title} text`}
        tabIndex={0}
        style={{ whiteSpace: "pre-wrap", overflowWrap: "anywhere" }}
      >
        {track ? (
          track[field] || <span className="text-secondary">No {field}.</span>
        ) : (
          <span className="text-secondary">No track playing.</span>
        )}
      </Modal.Body>
      {track && library().getTrackUserChanges() && (
        <Modal.Footer>
          <Button variant="primary" onClick={() => setEditTrack(track)}>
            Edit
          </Button>
        </Modal.Footer>
      )}
    </Modal>
  );
}

export default TrackTextReader;
