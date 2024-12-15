import { useEffect } from "react";
import { useAtomValue } from "jotai";
import {
  shuffleAtom,
  repeatAtom,
  volumeAtom,
  openedFoldersAtom,
  SetPersistedShuffle,
  SetPersistedRepeat,
  SetPersistedVolume,
  SetPersistedOpenedFolders as SetPersistedOpenedFolders,
} from "./Settings";

function SettingsRecorder() {
  const shuffle = useAtomValue(shuffleAtom);
  const repeat = useAtomValue(repeatAtom);
  const volume = useAtomValue(volumeAtom);
  const openedFolders = useAtomValue(openedFoldersAtom);

  useEffect(() => {
    SetPersistedShuffle(shuffle);
  }, [shuffle]);

  useEffect(() => {
    SetPersistedRepeat(repeat);
  }, [repeat]);

  useEffect(() => {
    SetPersistedVolume(volume);
  }, [volume]);

  useEffect(() => {
    SetPersistedOpenedFolders(openedFolders);
  }, [openedFolders]);

  return null;
}

export default SettingsRecorder;
