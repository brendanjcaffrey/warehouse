import library, { Track } from "./Library";
import { player } from "./Player";
import { updatePersister } from "./UpdatePersister";
import { TrackUpdate } from "./generated/messages";
import { store, updatedTrackAtom } from "./State";
import {
  changedFields,
  hasChanges,
  TrackEditForm,
  updatedTrack,
} from "./TrackEditForm";

// writes an edited track locally so every view refreshes at once: it goes into
// the library, the player swaps its copy and the track lists patch off the atom
export async function applyTrackEdit(updated: Track) {
  await library().putTrack(updated);
  player().trackUpdated(updated);
  store.set(updatedTrackAtom, updated);
}

// applies an edit form to a track, then queues just the changed fields for the
// server through the existing update mechanism. a no-op edit is skipped
export async function submitTrackEdit(form: TrackEditForm, track: Track) {
  const update = changedFields(form, track);
  if (!hasChanges(update)) {
    return;
  }
  await applyTrackEdit(updatedTrack(form, track));
  await updatePersister().updateTrack(track.id, update);
}

// sets a track's rating (0-100) from the interactive star displays, applying it
// locally and queuing just the rating change
export async function rateTrack(track: Track, rating: number) {
  const value = Math.round(rating);
  if (value === track.rating) {
    return;
  }
  await applyTrackEdit({ ...track, rating: value });
  const update = new TrackUpdate();
  update.rating = value;
  await updatePersister().updateTrack(track.id, update);
}
