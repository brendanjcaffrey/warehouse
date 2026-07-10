import { useState, useEffect, useCallback } from "react";
import { Modal, OverlayTrigger, Table, Tooltip } from "react-bootstrap";
import {
  IsTypedMessage,
  IsFileDownloadStatusMessage,
  FileType,
  DownloadStatus,
} from "./WorkerTypes";
import downloadsStore, { Download } from "./DownloadsStore";
import { DownloadWorker } from "./DownloadWorker";
import { formatBytes, formatTimestamp } from "./Util";

function FileTypeToString(fileType: FileType) {
  switch (fileType) {
    case FileType.MUSIC:
      return "music";
    case FileType.ARTWORK:
      return "artwork";
  }
}

function DownloadStatusToDisplay(download: Download): React.JSX.Element {
  switch (download.status) {
    case DownloadStatus.IN_PROGRESS:
      return <span>in progress</span>;
    case DownloadStatus.DONE:
      return <span>done</span>;
    case DownloadStatus.ERROR:
      return <span style={{ color: "var(--bs-danger)" }}>error</span>;
    case DownloadStatus.CANCELED:
      return <span>canceled</span>;
  }
}

function SizeDisplay(download: Download): React.JSX.Element {
  if (download.totalBytes === 0) {
    return <span>?</span>;
  }

  if (download.status === DownloadStatus.IN_PROGRESS) {
    return (
      <span>
        {formatBytes(download.receivedBytes)}/{formatBytes(download.totalBytes)}
      </span>
    );
  } else {
    return <span>{formatBytes(download.totalBytes)}</span>;
  }
}

interface DownloadsPanelProps {
  showDownloads: boolean;
  toggleShowDownloads: () => void;
}

function DownloadsPanel({
  showDownloads,
  toggleShowDownloads,
}: DownloadsPanelProps) {
  const [downloads, setDownloads] = useState<Download[]>([]);
  const handleDownloadWorkerMessage = useCallback(async (m: MessageEvent) => {
    const { data } = m;
    if (IsTypedMessage(data) && IsFileDownloadStatusMessage(data)) {
      await downloadsStore().update(data);
      setDownloads(downloadsStore().getAll());
    }
  }, []);

  useEffect(() => {
    DownloadWorker.addEventListener("message", handleDownloadWorkerMessage);
    return () => {
      DownloadWorker.removeEventListener(
        "message",
        handleDownloadWorkerMessage
      );
    };
  }, [handleDownloadWorkerMessage]);

  return (
    <Modal show={showDownloads} onHide={toggleShowDownloads} size="xl">
      <Modal.Header closeButton>
        <Modal.Title>Downloads</Modal.Title>
      </Modal.Header>
      <Modal.Body>
        {downloads.length === 0 && <p>No downloads yet</p>}
        {downloads.length > 0 && (
          <Table>
            <tbody>
              {downloads.map((d) => (
                <tr key={`${d.ids.trackId}-${d.ids.fileId}`}>
                  <td>
                    <OverlayTrigger
                      overlay={<Tooltip>track id: {d.ids.trackId}</Tooltip>}
                    >
                      <span>{d.trackDesc}</span>
                    </OverlayTrigger>
                  </td>
                  <td>
                    <OverlayTrigger
                      overlay={<Tooltip>file id: {d.ids.fileId}</Tooltip>}
                    >
                      <span>{FileTypeToString(d.fileType)}</span>
                    </OverlayTrigger>
                  </td>
                  <td>{DownloadStatusToDisplay(d)}</td>
                  <td>{SizeDisplay(d)}</td>
                  <td>{formatTimestamp(d.lastUpdate)}</td>
                </tr>
              ))}
            </tbody>
          </Table>
        )}
      </Modal.Body>
    </Modal>
  );
}

export default DownloadsPanel;
