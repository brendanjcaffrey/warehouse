import { useState, useEffect } from "react";
import { useAtom } from "jotai";
import {
  Form,
  Modal,
  OverlayTrigger,
  Popover,
  Toast,
  ToastContainer,
  Tooltip,
} from "react-bootstrap";
import { QuestionCircle } from "react-bootstrap-icons";
import { showArtworkAtom, keepModeAtom, downloadModeAtom } from "./Settings";
import { formatBytes } from "./Util";
import library from "./Library";
import IconButton from "./IconButton";
import LogOutButton from "./LogOutButton";

interface SettingsPanelProps {
  showSettings: boolean;
  toggleShowSettings: () => void;
}

const CONFIRM_MSG =
  "Are you sure you want to disable Keep Mode? This will delete all downloaded tracks and artwork.";
const FILE_OVERHEAD_ESTIMATE = 1.5;

const PERSIST_STORAGE_HELP =
  "Request that the browser allow this app to store data persistently and give " +
  "it a larger quota. Firefox will prompt you to allow this, but Chrome may not " +
  "allow this until you use the app more. Once granted, it is not possible to " +
  "revoke this permission.";
const KEEP_MODE_HELP =
  "Keep mode will retain all track and artwork downloads in the browser cache. " +
  "This can be useful for offline listening, but may consume a lot of storage " +
  "space. It is only available when storage is persisted and enough space is " +
  "available for the entire library plus overhead.";
const DOWNLOAD_MODE_HELP =
  "Download mode will aggressively download all music and artwork files at page " +
  "load so you can listen to your entire music library without having an internet " +
  "connection.";

function HelpPopover({ text }: { text: string }) {
  return (
    <OverlayTrigger
      trigger="click"
      rootClose
      placement="bottom-start"
      overlay={
        <Popover>
          <Popover.Body style={{ maxWidth: 300 }}>{text}</Popover.Body>
        </Popover>
      }
    >
      <IconButton>
        <QuestionCircle />
      </IconButton>
    </OverlayTrigger>
  );
}

function SettingsPanel({
  showSettings,
  toggleShowSettings,
}: SettingsPanelProps) {
  const [showArtwork, setShowArtwork] = useAtom(showArtworkAtom);
  const [persisted, setPersisted] = useState(false);
  const [haveEnoughStorageForKeepMode, setHaveEnoughStorageForKeepMode] =
    useState(false);
  const [keepMode, setKeepMode] = useAtom(keepModeAtom);
  const [downloadMode, setDownloadMode] = useAtom(downloadModeAtom);
  const [toastMsg, setToastMsg] = useState<string | null>(null);

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
        setToastMsg("Persistent storage was not granted.");
      }
    });
  };

  const handleKeepModeChange = (event: React.ChangeEvent<HTMLInputElement>) => {
    if (!event.target.checked && !window.confirm(CONFIRM_MSG)) {
      return;
    }
    if (!event.target.checked && downloadMode) {
      setDownloadMode(false);
    }
    setKeepMode(event.target.checked);
  };

  const handleDownloadModeChange = (
    event: React.ChangeEvent<HTMLInputElement>
  ) => {
    setDownloadMode(event.target.checked);
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
    <>
      <Modal show={showSettings} onHide={toggleShowSettings}>
        <Modal.Header closeButton>
          <Modal.Title>Settings</Modal.Title>
        </Modal.Header>
        <Modal.Body>
          <div style={{ width: "300px" }}>
            <Form.Check
              type="switch"
              id="show-artwork"
              label="Show Artwork"
              checked={showArtwork}
              onChange={handleShowArtworkChange}
            />
            <div className="d-flex align-items-center justify-content-between">
              <Form.Check
                type="switch"
                id="persist-storage"
                label="Persist Storage"
                checked={persisted}
                disabled={persisted}
                onChange={handlePersistStorageChange}
              />
              <HelpPopover text={PERSIST_STORAGE_HELP} />
            </div>
            <div className="d-flex align-items-center justify-content-between">
              <Form.Check
                type="switch"
                id="keep-mode"
                label="Keep Mode"
                checked={keepMode}
                onChange={handleKeepModeChange}
                disabled={!persisted || !haveEnoughStorageForKeepMode}
              />
              <HelpPopover text={KEEP_MODE_HELP} />
            </div>
            <div className="d-flex align-items-center justify-content-between">
              <Form.Check
                type="switch"
                id="download-mode"
                label="Download Mode"
                checked={downloadMode}
                onChange={handleDownloadModeChange}
                disabled={
                  !persisted || !haveEnoughStorageForKeepMode || !keepMode
                }
              />
              <HelpPopover text={DOWNLOAD_MODE_HELP} />
            </div>
            <OverlayTrigger
              overlay={
                <Tooltip>
                  {formatBytes(usage)} / {formatBytes(quota)}
                </Tooltip>
              }
            >
              <p className="mb-1">Storage Used: {percentageUsed}%</p>
            </OverlayTrigger>
            <p>
              Library Total Size: {formatBytes(library().getTotalFileSize())}
            </p>
            <LogOutButton />
          </div>
        </Modal.Body>
      </Modal>
      <ToastContainer position="bottom-end" className="p-3">
        <Toast
          show={!!toastMsg}
          onClose={() => setToastMsg(null)}
          bg="danger"
          delay={4000}
          autohide
        >
          <Toast.Body className="text-white">{toastMsg}</Toast.Body>
        </Toast>
      </ToastContainer>
    </>
  );
}

export default SettingsPanel;
