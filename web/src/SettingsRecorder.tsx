import { useEffect } from "react";
import { useAtom, useSetAtom } from "jotai";
import {
  shuffleAtom,
  repeatAtom,
  showArtworkAtom,
  volumeAtom,
  openedFoldersAtom,
  DEFAULT_VOLUME,
  SetPersistedShuffle,
  SetPersistedRepeat,
  SetPersistedShowArtwork,
  SetPersistedVolume,
  SetPersistedOpenedFolders,
} from "./Settings";
import { clearSettingsFnAtom } from "./State";

function SettingsRecorder() {
  const [shuffle, setShuffle] = useAtom(shuffleAtom);
  const [repeat, setRepeat] = useAtom(repeatAtom);
  const [showArtwork, setShowArtwork] = useAtom(showArtworkAtom);
  const [volume, setVolume] = useAtom(volumeAtom);
  const [openedFolders, setOpenedFolders] = useAtom(openedFoldersAtom);
  const setClearSettingsFn = useSetAtom(clearSettingsFnAtom);

  useEffect(() => {
    SetPersistedShuffle(shuffle);
  }, [shuffle]);

  useEffect(() => {
    SetPersistedRepeat(repeat);
  }, [repeat]);

  useEffect(() => {
    SetPersistedShowArtwork(showArtwork);
  }, [showArtwork]);

  useEffect(() => {
    SetPersistedVolume(volume);
  }, [volume]);

  useEffect(() => {
    SetPersistedOpenedFolders(openedFolders);
  }, [openedFolders]);

  useEffect(() => {
    setClearSettingsFn({
      fn: () => {
        setShuffle(false);
        setRepeat(false);
        setShowArtwork(false);
        setVolume(DEFAULT_VOLUME);
        setOpenedFolders(new Set());
      },
    });
  }, [
    setShuffle,
    setRepeat,
    setShowArtwork,
    setVolume,
    setOpenedFolders,
    setClearSettingsFn,
  ]);

  return null;
}

export default SettingsRecorder;
