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
} from "@mui/material";
import { HelpOutlineRounded } from "@mui/icons-material";
import { keepModeAtom } from "./Settings";
import { defaultGrey } from "./Colors";

interface StickyHeaderProps {
  showSettings: boolean;
  toggleShowSettings: () => void;
}

const formatBytes = (bytes: number, decimals = 2) => {
  if (!bytes) return "0 Bytes";
  const k = 1024;
  const sizes = ["b", "kb", "mb", "gb", "tb"];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return `${parseFloat((bytes / Math.pow(k, i)).toFixed(decimals))} ${
    sizes[i]
  }`;
};

function SettingsPanel({
  showSettings,
  toggleShowSettings,
}: StickyHeaderProps) {
  const [keepMode, setKeepMode] = useAtom(keepModeAtom);
  const [anchorEl, setAnchorEl] = useState<HTMLButtonElement | null>(null);
  const helpOpen = Boolean(anchorEl);

  const handleChange = (event: React.ChangeEvent<HTMLInputElement>) => {
    setKeepMode(event.target.checked);
  };

  const openHelp = (event: React.MouseEvent<HTMLButtonElement>) => {
    setAnchorEl(event.currentTarget);
  };

  const closeHelp = () => {
    setAnchorEl(null);
  };

  const [usage, setUsage] = useState(0);
  const [quota, setQuota] = useState(1);
  const percentageUsed = ((usage / quota) * 100).toFixed(2);

  useEffect(() => {
    const fetchStorageInfo = async () => {
      if (navigator.storage && navigator.storage.estimate) {
        const { usage, quota } = await navigator.storage.estimate();
        setUsage(usage || 0);
        setQuota(quota || 1);
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
        <FormControlLabel
          control={<Switch checked={keepMode} onChange={handleChange} />}
          label="Keep Mode"
        />
        <IconButton onClick={openHelp}>
          <HelpOutlineRounded />
        </IconButton>
        <Tooltip title={`${formatBytes(usage)} / ${formatBytes(quota)}`}>
          <p>Storage Used: {percentageUsed}%</p>
        </Tooltip>
        <Popover
          open={helpOpen}
          anchorEl={anchorEl}
          onClose={closeHelp}
          anchorOrigin={{
            vertical: "bottom",
            horizontal: "left",
          }}
        >
          Keep mode will retain all track and artwork downloads in the browser
          cache. This can be useful for offline listening, but may consume a lot
          of storage space.
        </Popover>
      </Box>
    </Modal>
  );
}

export default SettingsPanel;
