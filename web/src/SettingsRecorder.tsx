import { useEffect } from "react";
import { useAtomValue } from "jotai";
import {
  shuffleAtom,
  repeatAtom,
  volumeAtom,
  SetPersistedShuffle,
  SetPersistedRepeat,
  SetPersistedVolume,
} from "./Settings";

function SettingsRecorder() {
  const shuffle = useAtomValue(shuffleAtom);
  const repeat = useAtomValue(repeatAtom);
  const volume = useAtomValue(volumeAtom);

  useEffect(() => {
    SetPersistedShuffle(shuffle);
  }, [shuffle]);

  useEffect(() => {
    SetPersistedRepeat(repeat);
  }, [repeat]);

  useEffect(() => {
    SetPersistedVolume(volume);
  }, [volume]);

  return null;
}

export default SettingsRecorder;
