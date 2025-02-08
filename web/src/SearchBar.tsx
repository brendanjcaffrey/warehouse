import { useState } from "react";
import { useAtom } from "jotai";
import {
  Box,
  FormControl,
  Input,
  InputAdornment,
  Tooltip,
  IconButton,
} from "@mui/material";
import { SettingsRounded } from "@mui/icons-material";
import { SearchRounded } from "@mui/icons-material";
import { titleGrey } from "./Colors";
import { searchAtom } from "./State";
import SettingsPanel from "./SettingsPanel";

function SearchBar() {
  const [search, setSearch] = useAtom(searchAtom);
  const [showSettings, setShowSettings] = useState(false);

  const handleChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    setSearch(e.target.value);
  };

  const toggleShowSettings = () => {
    setShowSettings((prev) => !prev);
  };

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
          sx={{ fontSize: "12px", color: titleGrey }}
        />
      </FormControl>
      <Tooltip title="Settings">
        <IconButton
          size="large"
          onClick={toggleShowSettings}
          edge="start"
          sx={{ color: titleGrey }}
        >
          <SettingsRounded fontSize="inherit" />
        </IconButton>
      </Tooltip>
      <SettingsPanel
        showSettings={showSettings}
        toggleShowSettings={toggleShowSettings}
      />
    </Box>
  );
}

export default SearchBar;
