import { useEffect } from "react";
import { useAtom, useAtomValue, useSetAtom } from "jotai";
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
import { clearSettingsFnAtom } from "./State";

function SettingsRecorder() {
  const shuffle = useAtomValue(shuffleAtom);
  const repeat = useAtomValue(repeatAtom);
  const volume = useAtomValue(volumeAtom);
  const [openedFolders, setOpenedFolders] = useAtom(openedFoldersAtom);
  const setClearSettingsFn = useSetAtom(clearSettingsFnAtom);

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

  useEffect(() => {
    setClearSettingsFn({
      fn: () => {
        setOpenedFolders(new Set());
      },
    });
  }, [setOpenedFolders, setClearSettingsFn]);

  return null;
}

export default SettingsRecorder;
