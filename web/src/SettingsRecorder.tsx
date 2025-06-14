import { useEffect } from "react";
import { useAtom, useSetAtom } from "jotai";
import {
  keepModeAtom,
  downloadModeAtom,
  shuffleAtom,
  repeatAtom,
  showArtworkAtom,
  volumeAtom,
  openedFoldersAtom,
  DEFAULT_VOLUME,
  SetPersistedKeepMode,
  SetPersistedDownloadMode,
  SetPersistedShuffle,
  SetPersistedRepeat,
  SetPersistedShowArtwork,
  SetPersistedVolume,
  SetPersistedOpenedFolders,
} from "./Settings";
import { clearSettingsFnAtom } from "./State";
import { DownloadWorker } from "./DownloadWorker";
import {
  KEEP_MODE_CHANGED_TYPE,
  DOWNLOAD_MODE_CHANGED_TYPE,
  KeepModeChangedMessage,
  DownloadModeChangedMessage,
} from "./WorkerTypes";

function SettingsRecorder() {
  const [keepMode, setKeepMode] = useAtom(keepModeAtom);
  const [downloadMode, setDownloadMode] = useAtom(downloadModeAtom);
  const [shuffle, setShuffle] = useAtom(shuffleAtom);
  const [repeat, setRepeat] = useAtom(repeatAtom);
  const [showArtwork, setShowArtwork] = useAtom(showArtworkAtom);
  const [volume, setVolume] = useAtom(volumeAtom);
  const [openedFolders, setOpenedFolders] = useAtom(openedFoldersAtom);
  const setClearSettingsFn = useSetAtom(clearSettingsFnAtom);

  useEffect(() => {
    SetPersistedKeepMode(keepMode);
    DownloadWorker.postMessage({
      type: KEEP_MODE_CHANGED_TYPE,
      keepMode: keepMode,
    } as KeepModeChangedMessage);
  }, [keepMode]);

  useEffect(() => {
    SetPersistedDownloadMode(downloadMode);
    DownloadWorker.postMessage({
      type: DOWNLOAD_MODE_CHANGED_TYPE,
      downloadMode: downloadMode,
    } as DownloadModeChangedMessage);
  }, [downloadMode]);

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
        setKeepMode(false);
        setDownloadMode(false);
        setShuffle(false);
        setRepeat(false);
        setShowArtwork(false);
        setVolume(DEFAULT_VOLUME);
        setOpenedFolders(new Set());
      },
    });
  }, [
    setKeepMode,
    setDownloadMode,
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
