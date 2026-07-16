import { useState } from "react";
import { Button, Form, Modal } from "react-bootstrap";
import { Track } from "./Library";
import StarRating from "./StarRating";
import { formatDateAdded } from "./TrackColumns";
import { submitTrackEdit } from "./TrackEdit";
import {
  formFromTrack,
  isArtistValid,
  isFinishValid,
  isFormValid,
  isGenreValid,
  isNameValid,
  isStartValid,
  isYearValid,
  RATING_PER_STAR,
  TrackEditForm,
} from "./TrackEditForm";

// a labelled text field whose label reddens when the value is invalid, matching
// the ios edit form
function EditField({
  label,
  value,
  invalid,
  onChange,
}: {
  label: string;
  value: string;
  invalid: boolean;
  onChange: (value: string) => void;
}) {
  return (
    <Form.Group className="mb-3">
      <Form.Label className={invalid ? "text-danger mb-1" : "mb-1"}>
        {label}
      </Form.Label>
      <Form.Control
        type="text"
        value={value}
        isInvalid={invalid}
        onChange={(event) => onChange(event.target.value)}
      />
    </Form.Group>
  );
}

// the edit track sheet: mirrors the ios edit form's fields and validation, keeps
// rating interactive and plays read-only, and submits only the changed fields
// through the existing update mechanism
function EditTrackForm({
  track,
  onClose,
}: {
  track: Track;
  onClose: () => void;
}) {
  const [form, setForm] = useState<TrackEditForm>(() => formFromTrack(track));
  const [saving, setSaving] = useState(false);

  const update = (fields: Partial<TrackEditForm>) =>
    setForm((prev) => ({ ...prev, ...fields }));

  const save = async () => {
    setSaving(true);
    try {
      await submitTrackEdit(form, track);
      onClose();
    } finally {
      setSaving(false);
    }
  };

  const valid = isFormValid(form, track.duration);

  return (
    // stop keystrokes bubbling to an ancestor track list's type-to-search
    // handler, which would otherwise swallow typing in these inputs
    <Modal
      show
      onHide={onClose}
      centered
      onKeyDown={(event: React.KeyboardEvent) => event.stopPropagation()}
    >
      <Modal.Header closeButton>
        <Modal.Title>Edit Track</Modal.Title>
      </Modal.Header>
      <Modal.Body>
        <Form onSubmit={(event) => event.preventDefault()}>
          <EditField
            label="Name"
            value={form.name}
            invalid={!isNameValid(form)}
            onChange={(name) => update({ name })}
          />
          <EditField
            label="Artist"
            value={form.artist}
            invalid={!isArtistValid(form)}
            onChange={(artist) => update({ artist })}
          />
          <EditField
            label="Album"
            value={form.album}
            invalid={false}
            onChange={(album) => update({ album })}
          />
          <EditField
            label="Album Artist"
            value={form.albumArtist}
            invalid={false}
            onChange={(albumArtist) => update({ albumArtist })}
          />
          <EditField
            label="Genre"
            value={form.genre}
            invalid={!isGenreValid(form)}
            onChange={(genre) => update({ genre })}
          />
          <EditField
            label="Year"
            value={form.year}
            invalid={!isYearValid(form)}
            onChange={(year) => update({ year })}
          />
          <EditField
            label="Start"
            value={form.start}
            invalid={!isStartValid(form, track.duration)}
            onChange={(start) => update({ start })}
          />
          <EditField
            label="Finish"
            value={form.finish}
            invalid={!isFinishValid(form, track.duration)}
            onChange={(finish) => update({ finish })}
          />
          <div className="mb-3 d-flex align-items-center justify-content-between">
            <Form.Label className="mb-0">Rating</Form.Label>
            <StarRating
              rating={form.rating * RATING_PER_STAR}
              size={20}
              onRate={(rating) => update({ rating: rating / RATING_PER_STAR })}
            />
          </div>
          <div className="mb-3 d-flex align-items-center justify-content-between">
            <Form.Label className="mb-0">Plays</Form.Label>
            <span className="text-secondary">{track.playCount}</span>
          </div>
          <div className="d-flex align-items-center justify-content-between">
            <Form.Label className="mb-0">Added</Form.Label>
            <span className="text-secondary">
              {formatDateAdded(track.addedDate)}
            </span>
          </div>
        </Form>
      </Modal.Body>
      <Modal.Footer>
        <Button variant="secondary" onClick={onClose} disabled={saving}>
          cancel
        </Button>
        <Button variant="primary" onClick={save} disabled={!valid || saving}>
          save
        </Button>
      </Modal.Footer>
    </Modal>
  );
}

export default EditTrackForm;
