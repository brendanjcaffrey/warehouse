import { useState, useEffect } from "react";
import {
  Dialog,
  DialogTitle,
  DialogContent,
  DialogActions,
  Button,
  TextField,
  InputLabel,
} from "@mui/material";
import { FieldDefinition, EDIT_TRACK_FIELDS } from "./EditTrackFields";
import { store, trackUpdatedFnAtom } from "./State";
import library, { Track } from "./Library";
import { player } from "./Player";
import { updatePersister } from "./UpdatePersister";
import { EditTrackArtwork } from "./EditTrackArtwork";

interface EditTrackPanelProps {
  open: boolean;
  track: Track | undefined;
  setTrack: (track: Track | undefined) => void;
  closeEditTrackPanel: () => void;
}

interface Field {
  definition: FieldDefinition;
  stateValue: string;
  setStateValue: (v: string) => void;
  valid: boolean;
}

function EditTrackPanel({
  open,
  setTrack,
  track,
  closeEditTrackPanel,
}: EditTrackPanelProps) {
  const fields: Field[] = EDIT_TRACK_FIELDS.map((definition) => {
    // eslint-disable-next-line react-hooks/rules-of-hooks
    const [stateValue, setStateValue] = useState("");
    return {
      definition,
      stateValue,
      setStateValue,
      valid: track ? definition.validate(stateValue, track) : false,
    };
  });
  const submitEnabled = fields.map((f) => f.valid).reduce((p, c) => p && c);

  useEffect(() => {
    if (!track) {
      return;
    }
    for (const field of fields) {
      field.setStateValue(field.definition.getDisplayTrackValue(track));
    }
  }, [track]); // eslint-disable-line react-hooks/exhaustive-deps

  const [artworkCleared, setArtworkCleared] = useState(false);
  const [uploadedImageFilename, setUploadedImageFilename] = useState<
    string | null
  >(null);

  const submitEdits = async (event: React.FormEvent) => {
    event.preventDefault();
    closeEditTrackPanel();

    if (!track) {
      return;
    }

    const updatedTrack = await library().getTrack(track.id);
    if (!updatedTrack) {
      return;
    }

    const updatedFields: { [key: string]: string } = {};
    for (const field of fields) {
      if (field.stateValue !== field.definition.getDisplayTrackValue(track)) {
        field.definition.setTrackValue(updatedTrack, field.stateValue);
        const getter =
          field.definition.getApiTrackValue ??
          field.definition.getDisplayTrackValue;
        updatedFields[field.definition.name] = getter(updatedTrack);
      }
    }

    if (uploadedImageFilename) {
      if (updatedTrack.artwork !== uploadedImageFilename) {
        updatedTrack.artwork = uploadedImageFilename;
        updatedFields.artwork = uploadedImageFilename;
      }
    } else if (artworkCleared) {
      updatedTrack.artwork = null;
      updatedFields.artwork = "";
    }

    if (Object.keys(updatedFields).length > 0) {
      await library().putTrack(updatedTrack);
      store.get(trackUpdatedFnAtom).fn(updatedTrack);
      player().trackInfoUpdated(updatedTrack);
      updatePersister().updateTrackInfo(track?.id, updatedFields);
    }
  };

  return (
    <Dialog
      open={open}
      onClose={closeEditTrackPanel}
      maxWidth="xl"
      slotProps={{
        transition: {
          onExited: () => {
            setTrack(undefined);
          },
        },
      }}
    >
      <form onSubmit={submitEdits}>
        <DialogTitle>Edit Track</DialogTitle>
        <DialogContent>
          {fields.map((f) => (
            <TextField
              key={f.definition.name}
              id={f.definition.name}
              name={f.definition.name}
              label={f.definition.label}
              value={f.stateValue}
              onChange={(e) => {
                f.setStateValue(e.target.value);
              }}
              error={!f.valid}
              fullWidth
              autoComplete="off"
              margin="dense"
              variant="standard"
              type="text"
            />
          ))}
          <InputLabel shrink={true} sx={{ marginTop: "8px" }}>
            Album Artwork
          </InputLabel>
          <EditTrackArtwork
            track={track}
            artworkCleared={artworkCleared}
            setArtworkCleared={setArtworkCleared}
            uploadedImageFilename={uploadedImageFilename}
            setUploadedImageFilename={setUploadedImageFilename}
          />
        </DialogContent>
        <DialogActions>
          <Button onClick={closeEditTrackPanel}>Cancel</Button>
          <Button type="submit" disabled={!submitEnabled}>
            Submit
          </Button>
        </DialogActions>
      </form>
    </Dialog>
  );
}

export default EditTrackPanel;
