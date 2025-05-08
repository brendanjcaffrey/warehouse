import { useState, useEffect } from "react";
import {
  Dialog,
  DialogTitle,
  DialogContent,
  DialogActions,
  Button,
  TextField,
} from "@mui/material";
import { Track } from "./Library";
import { FormatPlaybackPositionWithMillis } from "./PlaybackPositionFormatters";

interface EditTrackPanelProps {
  track: Track | null;
  closeEditTrackPanel: () => void;
}

interface Field {
  name: string;
  label: string;
  value: string;
  setValue: (v: string) => void;
}

function EditTrackPanel({ track, closeEditTrackPanel }: EditTrackPanelProps) {
  const [name, setName] = useState("");
  const [artist, setArtist] = useState("");
  const [album, setAlbum] = useState("");
  const [albumArtist, setAlbumArtist] = useState("");
  const [genre, setGenre] = useState("");
  const [year, setYear] = useState("");
  const [start, setStart] = useState("");
  const [finish, setFinish] = useState("");

  useEffect(() => {
    if (!track) {
      return;
    }
    setName(track.name);
    setArtist(track.artistName);
    setAlbum(track.albumName);
    setAlbumArtist(track.albumArtistName);
    setGenre(track.genre);
    setYear(track.year.toString());
    setStart(FormatPlaybackPositionWithMillis(track.start));
    setFinish(FormatPlaybackPositionWithMillis(track.finish));
  }, [track]);

  const fields: Field[] = [
    { name: "name", label: "Name", value: name, setValue: setName },
    { name: "artist", label: "Artist", value: artist, setValue: setArtist },
    { name: "album", label: "Album", value: album, setValue: setAlbum },
    {
      name: "albumArtist",
      label: "Album Artist",
      value: albumArtist,
      setValue: setAlbumArtist,
    },
    { name: "genre", label: "Genre", value: genre, setValue: setGenre },
    { name: "year", label: "Year", value: year, setValue: setYear },
    { name: "start", label: "Start", value: start, setValue: setStart },
    { name: "finish", label: "Finish", value: finish, setValue: setFinish },
  ];

  return (
    <Dialog open={!!track} onClose={closeEditTrackPanel} maxWidth="xl">
      <DialogTitle>Edit Track</DialogTitle>
      <DialogContent>
        {fields.map((f) => (
          <TextField
            key={f.name}
            id={f.name}
            name={f.name}
            label={f.label}
            value={f.value}
            onChange={(e) => {
              f.setValue(e.target.value);
            }}
            fullWidth
            autoComplete="off"
            margin="dense"
            variant="standard"
            type="text"
          />
        ))}
      </DialogContent>
      <DialogActions>
        <Button onClick={closeEditTrackPanel}>Cancel</Button>
        <Button>Submit</Button>
      </DialogActions>
    </Dialog>
  );
}

export default EditTrackPanel;
