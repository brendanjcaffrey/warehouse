import { useState } from "react";
import { useAtom, useAtomValue } from "jotai";
import {
  useTheme,
  useMediaQuery,
  Box,
  Popover,
  FormControl,
  Input,
  InputAdornment,
  Tooltip,
  IconButton,
  Badge,
} from "@mui/material";
import { SettingsRounded, DownloadRounded } from "@mui/icons-material";
import { SearchRounded } from "@mui/icons-material";
import { anyDownloadErrorsAtom, searchAtom } from "./State";
import DownloadsPanel from "./DownloadsPanel";
import SettingsPanel from "./SettingsPanel";

function SearchBar() {
  const theme = useTheme();
  const isSmallScreen = useMediaQuery(theme.breakpoints.down("lg"));

  const [search, setSearch] = useAtom(searchAtom);
  const [popoverAnchorEl, setPopoverAnchorEl] = useState<null | HTMLElement>(
    null
  );
  const popoverOpen = Boolean(popoverAnchorEl);
  const handleOpenPopover = (event: React.MouseEvent<HTMLButtonElement>) => {
    setPopoverAnchorEl(event.currentTarget);
  };
  const handleClosePopover = () => {
    setPopoverAnchorEl(null);
  };

  const haveSearchTerm = search.length > 0;
  const anyDownloadErrors = useAtomValue(anyDownloadErrorsAtom);

  const [showDownloads, setShowDownloads] = useState(false);
  const [showSettings, setShowSettings] = useState(false);

  const handleChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    setSearch(e.target.value);
  };

  const toggleShowDownloads = () => {
    setShowDownloads((prev) => !prev);
  };

  const toggleShowSettings = () => {
    setShowSettings((prev) => !prev);
  };

  const searchBar = (
    <FormControl sx={{ p: "12px", width: "25ch" }} variant="standard">
      <Input
        type="search"
        placeholder="Search"
        value={search}
        onChange={handleChange}
        endAdornment={
          <InputAdornment position="end">
            <SearchRounded sx={{ pb: "5px" }} />
          </InputAdornment>
        }
        sx={{ fontSize: "12px", color: theme.palette.text.primary }}
      />
    </FormControl>
  );

  return (
    <Box
      sx={{
        display: "flex",
        alignItems: "center",
        justifyContent: "flex-end",
        width: "100%",
        height: "100%",
      }}
    >
      {isSmallScreen ? (
        <>
          <IconButton onClick={handleOpenPopover}>
            <Badge color="secondary" variant="dot" invisible={!haveSearchTerm}>
              <SearchRounded />
            </Badge>
          </IconButton>
          <Popover
            open={popoverOpen}
            anchorEl={popoverAnchorEl}
            onClose={handleClosePopover}
            anchorOrigin={{
              vertical: "bottom",
              horizontal: "left",
            }}
          >
            <Box sx={{ minWidth: 240 }}>{searchBar}</Box>
          </Popover>
        </>
      ) : (
        searchBar
      )}
      <Tooltip title="Download Status">
        <IconButton size="large" onClick={toggleShowDownloads} edge="start">
          <Badge color="error" variant="dot" invisible={!anyDownloadErrors}>
            <DownloadRounded fontSize="inherit" />
          </Badge>
        </IconButton>
      </Tooltip>
      <Tooltip title="Settings">
        <IconButton size="large" onClick={toggleShowSettings} edge="start">
          <SettingsRounded fontSize="inherit" />
        </IconButton>
      </Tooltip>
      <DownloadsPanel
        showDownloads={showDownloads}
        toggleShowDownloads={toggleShowDownloads}
      />
      <SettingsPanel
        showSettings={showSettings}
        toggleShowSettings={toggleShowSettings}
      />
    </Box>
  );
}

export default SearchBar;
