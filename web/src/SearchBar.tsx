import { useState } from "react";
import { Box, FormControl, Input, InputAdornment } from "@mui/material";
import { SearchRounded } from "@mui/icons-material";
import { titleGrey } from "./Colors";

function SearchBar() {
  const [search, setSearch] = useState("");

  const handleChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    setSearch(e.target.value);
  };

  return (
    <Box
      sx={{
        display: "flex",
        alignItems: "center",
        justifyContent: "flex-end",
        width: "100%",
        height: "52px",
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
    </Box>
  );
}

export default SearchBar;
