import { useState, useEffect, useCallback } from "react";
import {
  Modal,
  Box,
  Table,
  TableBody,
  TableRow,
  TableCell,
  Tooltip,
} from "@mui/material";
import {
  IsTypedMessage,
  IsFileDownloadStatusMessage,
  FileType,
  DownloadStatus,
} from "./WorkerTypes";
import downloadsStore, { Download } from "./DownloadsStore";
import { DownloadWorker } from "./DownloadWorkerHandle";
import { formatBytes, formatTimestamp } from "./Util";
import { defaultGrey } from "./Colors";

function FileTypeToString(fileType: FileType) {
  switch (fileType) {
    case FileType.MUSIC:
      return "music";
    case FileType.ARTWORK:
      return "artwork";
  }
}

function DownloadStatusToDisplay(download: Download): JSX.Element {
  switch (download.status) {
    case DownloadStatus.IN_PROGRESS:
      return <span>in progress</span>;
    case DownloadStatus.DONE:
      return <span>done</span>;
    case DownloadStatus.ERROR:
      return <span color="red">error</span>;
    case DownloadStatus.CANCELED:
      return <span>canceled</span>;
  }
}

function SizeDisplay(download: Download): JSX.Element {
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
    <Modal open={showDownloads} onClose={toggleShowDownloads}>
      <Box
        sx={{
          outline: 0,
          position: "absolute",
          width: "50vw",
          maxHeight: "50vh",
          overflowY: "auto",
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
        <h3>Downloads</h3>
        <Table>
          <TableBody>
            {downloads.map((d) => (
              <TableRow key={`${d.ids.trackId}-${d.ids.fileId}`}>
                <TableCell>
                  <Tooltip title={`track id: ${d.ids.trackId}`}>
                    <span>{d.trackName}</span>
                  </Tooltip>
                </TableCell>
                <TableCell>
                  <Tooltip title={`file id: ${d.ids.fileId}`}>
                    <span>{FileTypeToString(d.fileType)}</span>
                  </Tooltip>
                </TableCell>
                <TableCell>{DownloadStatusToDisplay(d)}</TableCell>
                <TableCell>{SizeDisplay(d)}</TableCell>
                <TableCell>{formatTimestamp(d.lastUpdate)}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </Box>
    </Modal>
  );
}

export default DownloadsPanel;
