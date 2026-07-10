import { useEffect } from "react";
import { useAtomValue, useSetAtom } from "jotai";
import { RESET } from "jotai/utils";
import {
  keepModeAtom,
  downloadModeAtom,
  shuffleAtom,
  repeatAtom,
  showArtworkAtom,
  volumeAtom,
  openedFoldersAtom,
  sidebarWidthAtom,
} from "./Settings";
import { clearSettingsFnAtom } from "./State";
import { DownloadWorker } from "./DownloadWorker";
import {
  KEEP_MODE_CHANGED_TYPE,
  DOWNLOAD_MODE_CHANGED_TYPE,
  KeepModeChangedMessage,
  DownloadModeChangedMessage,
} from "./WorkerTypes";

function SettingsEffects() {
  const keepMode = useAtomValue(keepModeAtom);
  const downloadMode = useAtomValue(downloadModeAtom);

  const resetKeepMode = useSetAtom(keepModeAtom);
  const resetDownloadMode = useSetAtom(downloadModeAtom);
  const resetShuffle = useSetAtom(shuffleAtom);
  const resetRepeat = useSetAtom(repeatAtom);
  const resetShowArtwork = useSetAtom(showArtworkAtom);
  const resetVolume = useSetAtom(volumeAtom);
  const resetOpenedFolders = useSetAtom(openedFoldersAtom);
  const resetSidebarWidth = useSetAtom(sidebarWidthAtom);
  const setClearSettingsFn = useSetAtom(clearSettingsFnAtom);

  useEffect(() => {
    DownloadWorker.postMessage({
      type: KEEP_MODE_CHANGED_TYPE,
      keepMode: keepMode,
    } as KeepModeChangedMessage);
  }, [keepMode]);

  useEffect(() => {
    DownloadWorker.postMessage({
      type: DOWNLOAD_MODE_CHANGED_TYPE,
      downloadMode: downloadMode,
    } as DownloadModeChangedMessage);
  }, [downloadMode]);

  useEffect(() => {
    setClearSettingsFn({
      fn: () => {
        resetKeepMode(RESET);
        resetDownloadMode(RESET);
        resetShuffle(RESET);
        resetRepeat(RESET);
        resetShowArtwork(RESET);
        resetVolume(RESET);
        resetOpenedFolders(RESET);
        resetSidebarWidth(RESET);
      },
    });
  }, [
    resetKeepMode,
    resetDownloadMode,
    resetShuffle,
    resetRepeat,
    resetShowArtwork,
    resetVolume,
    resetOpenedFolders,
    resetSidebarWidth,
    setClearSettingsFn,
  ]);

  return null;
}

export default SettingsEffects;
