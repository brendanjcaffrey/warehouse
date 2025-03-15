import { useState, useEffect } from "react";
import { useAtom } from "jotai";
import {
  Modal,
  Box,
  FormControlLabel,
  Switch,
  IconButton,
  Popover,
  Tooltip,
  Grid2 as Grid,
} from "@mui/material";
import { HelpOutlineRounded } from "@mui/icons-material";
import { enqueueSnackbar } from "notistack";
import { showArtworkAtom, keepModeAtom } from "./Settings";
import { defaultGrey } from "./Colors";
import { formatBytes } from "./Util";
import library from "./Library";

interface SettingsPanelProps {
  showSettings: boolean;
  toggleShowSettings: () => void;
}

const CONFIRM_MSG =
  "Are you sure you want to disable Keep Mode? This will delete all downloaded tracks and artwork.";
const FILE_OVERHEAD_ESTIMATE = 1.5;

function SettingsPanel({
  showSettings,
  toggleShowSettings,
}: SettingsPanelProps) {
  const [showArtwork, setShowArtwork] = useAtom(showArtworkAtom);
  const [persisted, setPersisted] = useState(false);
  const [haveEnoughStorageForKeepMode, setHaveEnoughStorageForKeepMode] =
    useState(false);
  const [keepMode, setKeepMode] = useAtom(keepModeAtom);

  const [persistStorageHelpAnchorEl, setPersistStorageHelpAnchorEl] =
    useState<HTMLButtonElement | null>(null);
  const persistStorageHelpOpen = Boolean(persistStorageHelpAnchorEl);

  const [keepModeHelpAnchorEl, setKeepModeHelpAnchorEl] =
    useState<HTMLButtonElement | null>(null);
  const keepModeHelpOpen = Boolean(keepModeHelpAnchorEl);

  const handleShowArtworkChange = (
    event: React.ChangeEvent<HTMLInputElement>
  ) => {
    setShowArtwork(event.target.checked);
  };
  const handlePersistStorageChange = (
    event: React.ChangeEvent<HTMLInputElement>
  ) => {
    if (persisted || !event.target.checked) {
      return;
    }
    navigator.storage.persist().then((granted) => {
      if (granted) {
        setPersisted(true);
      } else {
        enqueueSnackbar("Persistent storage was not granted.", {
          variant: "error",
        });
      }
    });
  };

  const handleKeepModeChange = (event: React.ChangeEvent<HTMLInputElement>) => {
    if (!event.target.checked && !window.confirm(CONFIRM_MSG)) {
      return;
    }
    setKeepMode(event.target.checked);
  };

  const openPersistStorageHelp = (
    event: React.MouseEvent<HTMLButtonElement>
  ) => {
    setPersistStorageHelpAnchorEl(event.currentTarget);
  };

  const closePersistStorageHelp = () => {
    setPersistStorageHelpAnchorEl(null);
  };

  const openKeepModeHelp = (event: React.MouseEvent<HTMLButtonElement>) => {
    setKeepModeHelpAnchorEl(event.currentTarget);
  };

  const closeKeepModeHelp = () => {
    setKeepModeHelpAnchorEl(null);
  };

  const [usage, setUsage] = useState(0);
  const [quota, setQuota] = useState(1);
  const percentageUsed = ((usage / quota) * 100).toFixed(2);

  useEffect(() => {
    const fetchStorageInfo = async () => {
      const totalSize = library().getTotalFileSize();
      if (navigator.storage && navigator.storage.estimate) {
        const { usage, quota } = await navigator.storage.estimate();
        setUsage(usage || 0);
        setQuota(quota || 1);

        if (quota && usage) {
          setHaveEnoughStorageForKeepMode(
            totalSize * FILE_OVERHEAD_ESTIMATE < quota - usage
          );
        } else {
          setHaveEnoughStorageForKeepMode(false);
        }
      }

      if (navigator.storage && (await navigator.storage.persisted())) {
        setPersisted(true);
      } else {
        setPersisted(false);
      }
    };

    fetchStorageInfo();
    const interval = setInterval(fetchStorageInfo, 5000);

    return () => clearInterval(interval);
  }, []);

  return (
    <Modal open={showSettings} onClose={toggleShowSettings}>
      <Box
        sx={{
          outline: 0,
          position: "absolute",
          top: "50%",
          left: "50%",
          transform: "translate(-50%, -50%)",
          bgcolor: "background.paper",
          border: `1px solid ${defaultGrey}`,
          borderRadius: 2,
          boxShadow: 12,
          p: 4,
        }}
      >
        <Grid container spacing={0} sx={{ width: "300px" }}>
          <Grid size={10}>
            <FormControlLabel
              control={
                <Switch
                  checked={showArtwork}
                  onChange={handleShowArtworkChange}
                />
              }
              label="Show Artwork"
            />
          </Grid>
          <Grid size={10}>
            <FormControlLabel
              control={
                <Switch
                  checked={persisted}
                  disabled={persisted}
                  onChange={handlePersistStorageChange}
                />
              }
              label="Persist Storage"
            />
          </Grid>
          <Grid size={2}>
            <IconButton onClick={openPersistStorageHelp}>
              <HelpOutlineRounded sx={{ float: "right" }} />
            </IconButton>
          </Grid>

          <Grid size={10}>
            <FormControlLabel
              control={
                <Switch
                  checked={keepMode}
                  onChange={handleKeepModeChange}
                  disabled={!persisted || !haveEnoughStorageForKeepMode}
                />
              }
              label="Keep Mode"
            />
          </Grid>
          <Grid size={2}>
            <IconButton onClick={openKeepModeHelp}>
              <HelpOutlineRounded />
            </IconButton>
          </Grid>
          <Grid size={12}>
            <Tooltip title={`${formatBytes(usage)} / ${formatBytes(quota)}`}>
              <p>Storage Used: {percentageUsed}%</p>
            </Tooltip>

            <p>
              Library Total Size: {formatBytes(library().getTotalFileSize())}
            </p>
          </Grid>
        </Grid>
        <Popover
          open={persistStorageHelpOpen}
          anchorEl={persistStorageHelpAnchorEl}
          onClose={closePersistStorageHelp}
          anchorOrigin={{
            vertical: "bottom",
            horizontal: "left",
          }}
        >
          <div style={{ padding: "10px", maxWidth: "300px" }}>
            Request that the browser allow this app to store data persistently
            and give it a larger quota. Firefox will prompt you to allow this,
            but Chrome may not allow this until you use the app more. Once
            granted, it is not possible to revoke this permission.
          </div>
        </Popover>
        <Popover
          open={keepModeHelpOpen}
          anchorEl={keepModeHelpAnchorEl}
          onClose={closeKeepModeHelp}
          anchorOrigin={{
            vertical: "bottom",
            horizontal: "left",
          }}
        >
          <div style={{ padding: "10px", maxWidth: "300px" }}>
            Keep mode will retain all track and artwork downloads in the browser
            cache. This can be useful for offline listening, but may consume a
            lot of storage space. It is only available when storage is persisted
            and enough space is available for the entire library plus overhead.
          </div>
        </Popover>
      </Box>
    </Modal>
  );
}

export default SettingsPanel;
