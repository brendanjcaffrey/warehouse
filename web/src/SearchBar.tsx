import { ReactNode, useState } from "react";
import { useAtom, useAtomValue } from "jotai";
import {
  Form,
  InputGroup,
  OverlayTrigger,
  Popover,
  Tooltip,
} from "react-bootstrap";
import { Gear, Download, Search } from "react-bootstrap-icons";
import { anyDownloadErrorsAtom, searchAtom } from "./State";
import useBreakpoint from "@restart/hooks/useBreakpoint";
import IconButton from "./IconButton";
import DownloadsPanel from "./DownloadsPanel";
import SettingsPanel from "./SettingsPanel";

interface DotBadgeProps {
  show: boolean;
  color: string;
  children: ReactNode;
}

function DotBadge({ show, color, children }: DotBadgeProps) {
  return (
    <span className="position-relative d-inline-flex">
      {children}
      {show && (
        <span
          className="position-absolute translate-middle rounded-circle"
          style={{
            top: 2,
            left: "100%",
            width: 8,
            height: 8,
            backgroundColor: color,
          }}
        />
      )}
    </span>
  );
}

function SearchBar() {
  const isSmallScreen = useBreakpoint("lg", "down");

  const [search, setSearch] = useAtom(searchAtom);
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
    <InputGroup style={{ padding: "12px", width: "25ch" }}>
      <Form.Control
        type="search"
        placeholder="Search"
        value={search}
        onChange={handleChange}
        style={{ fontSize: "12px" }}
      />
      <InputGroup.Text>
        <Search />
      </InputGroup.Text>
    </InputGroup>
  );

  return (
    <div className="d-flex align-items-center justify-content-end w-100 h-100">
      {isSmallScreen ? (
        <OverlayTrigger
          trigger="click"
          rootClose
          placement="bottom-start"
          overlay={
            <Popover>
              <Popover.Body style={{ minWidth: 240, padding: 0 }}>
                {searchBar}
              </Popover.Body>
            </Popover>
          }
        >
          <IconButton>
            <DotBadge show={haveSearchTerm} color="var(--bs-primary)">
              <Search size={26} />
            </DotBadge>
          </IconButton>
        </OverlayTrigger>
      ) : (
        searchBar
      )}
      <OverlayTrigger
        placement="bottom"
        overlay={<Tooltip>Download Status</Tooltip>}
      >
        <IconButton onClick={toggleShowDownloads}>
          <DotBadge show={anyDownloadErrors} color="var(--bs-danger)">
            <Download size={26} />
          </DotBadge>
        </IconButton>
      </OverlayTrigger>
      <OverlayTrigger placement="bottom" overlay={<Tooltip>Settings</Tooltip>}>
        <IconButton onClick={toggleShowSettings}>
          <Gear size={26} />
        </IconButton>
      </OverlayTrigger>
      <DownloadsPanel
        showDownloads={showDownloads}
        toggleShowDownloads={toggleShowDownloads}
      />
      <SettingsPanel
        showSettings={showSettings}
        toggleShowSettings={toggleShowSettings}
      />
    </div>
  );
}

export default SearchBar;
