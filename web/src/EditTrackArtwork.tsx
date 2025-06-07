import {
  useState,
  useEffect,
  useCallback,
  useRef,
  DragEvent,
  ChangeEvent,
} from "react";
import { useArtworkFileURL } from "./useArtworkFileURL";
import { Track } from "./Library";
import { DownloadWorker } from "./DownloadWorkerHandle";
import {
  FileRequestSource,
  FileType,
  SET_SOURCE_REQUESTED_FILES_TYPE,
  SetSourceRequestedFilesMessage,
  TrackFileIds,
} from "./WorkerTypes";
import DelayedElement from "./DelayedElement";
import { CircularProgress, ClickAwayListener, useTheme } from "@mui/material";
import { UploadFileRounded } from "@mui/icons-material";
import { enqueueSnackbar } from "notistack";

interface EditTrackArtworkProps {
  track: Track | undefined;
}

enum ArtworkDisplayState {
  NONE,
  LOADING,
  LOADED,
  UPLOAD,
}

const ARTWORK_SIZE = 100;
const SPINNER_SIZE = 50;
const BORDER_WIDTH = 2;
const SPINNER_CONTAINER_SIZE = ARTWORK_SIZE + BORDER_WIDTH * 2;
const MAX_FILE_SIZE = 100 * 1024 * 1024; // 100 MB

export function EditTrackArtwork({ track }: EditTrackArtworkProps) {
  const theme = useTheme();
  const artworkFileURL = useArtworkFileURL(track);
  const [artworkSelected, setArtworkSelected] = useState(false);
  const [artworkCleared, setArtworkCleared] = useState(false);
  const [uploadedImage, setUploadedImage] = useState<string | null>(null);

  useEffect(() => {
    setArtworkCleared(false);
    setArtworkSelected(false);
    setUploadedImage(null);

    var preloadArtworkIds: TrackFileIds[] = [];
    if (track && track.artwork) {
      preloadArtworkIds = [{ trackId: track.id, fileId: track.artwork }];
    }
    DownloadWorker.postMessage({
      type: SET_SOURCE_REQUESTED_FILES_TYPE,
      source: FileRequestSource.EDIT_TRACK_ARTWORK,
      fileType: FileType.ARTWORK,
      ids: preloadArtworkIds,
    } as SetSourceRequestedFilesMessage);
  }, [track]);

  const clearOnDelete = useCallback(
    (event: KeyboardEvent) => {
      if (event.target instanceof HTMLInputElement) {
        return;
      }
      if (event.key !== "Backspace" && event.key !== "Delete") {
        return;
      }
      if (track && artworkSelected) {
        setArtworkSelected(false);
        setArtworkCleared(true);
        setUploadedImage(null);
      }
    },
    [
      track,
      artworkSelected,
      setArtworkCleared,
      setUploadedImage,
      setArtworkSelected,
    ]
  );

  useEffect(() => {
    document.addEventListener("keydown", clearOnDelete);
    return () => {
      document.addEventListener("keydown", clearOnDelete);
    };
  }, [clearOnDelete]);

  const [dragHovering, setDragHovering] = useState(false);
  const handleDragOver = useCallback((event: DragEvent) => {
    event.preventDefault();
    setDragHovering(true);
  }, []);

  const handleDragLeave = useCallback((event: DragEvent) => {
    event.preventDefault();
    setDragHovering(false);
  }, []);

  const inputRef = useRef<HTMLInputElement>(null);
  const openInput = () => {
    if (inputRef.current) {
      inputRef.current.click();
    }
  };

  const handleFileChange = (file: File) => {
    if (file.size > MAX_FILE_SIZE) {
      enqueueSnackbar("File size exceeds 100 MB limit.", { variant: "error" });
      return;
    }
    const reader = new FileReader();
    reader.onloadend = () => {
      if (typeof reader.result === "string") {
        setUploadedImage(reader.result);
      }
    };
    reader.readAsDataURL(file);
  };

  const handleChange = useCallback((event: ChangeEvent<HTMLInputElement>) => {
    const files = event.target.files;
    if (files && files[0]) {
      handleFileChange(files[0]);
    }
  }, []);

  const handleDrop = useCallback((event: DragEvent) => {
    event.preventDefault();
    setDragHovering(false);
    const files = event.dataTransfer.files;
    if (files && files[0]) {
      handleFileChange(files[0]);
    }
  }, []);

  var artworkDisplayState = ArtworkDisplayState.NONE;
  if (track) {
    if (uploadedImage) {
      artworkDisplayState = ArtworkDisplayState.LOADED;
    } else if (track.artwork && !artworkCleared) {
      artworkDisplayState = artworkFileURL
        ? ArtworkDisplayState.LOADED
        : ArtworkDisplayState.LOADING;
    } else {
      artworkDisplayState = ArtworkDisplayState.UPLOAD;
    }
  }

  switch (artworkDisplayState) {
    case ArtworkDisplayState.NONE:
      return null;
    case ArtworkDisplayState.LOADING:
      return (
        <DelayedElement>
          <div
            style={{
              width: `${SPINNER_CONTAINER_SIZE}px`,
              height: `${SPINNER_CONTAINER_SIZE}px`,
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
            }}
          >
            <CircularProgress size={SPINNER_SIZE} />
          </div>
        </DelayedElement>
      );
    case ArtworkDisplayState.LOADED:
      return (
        <ClickAwayListener onClickAway={() => setArtworkSelected(false)}>
          <img
            src={uploadedImage ?? artworkFileURL!}
            style={{
              width: `${ARTWORK_SIZE}px`,
              height: `${ARTWORK_SIZE}px`,
              display: "block",
              border: `${BORDER_WIDTH}px solid ${artworkSelected ? theme.palette.error.main : "transparent"}`,
            }}
            onClick={() => setArtworkSelected(true)}
          />
        </ClickAwayListener>
      );
    case ArtworkDisplayState.UPLOAD:
      return (
        <div
          style={{
            width: `${ARTWORK_SIZE}px`,
            height: `${ARTWORK_SIZE}px`,
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            cursor: "pointer",
            border: `${BORDER_WIDTH}px dashed ${dragHovering ? theme.palette.primary.dark : theme.palette.primary.light}`,
          }}
          onDragOver={handleDragOver}
          onDragLeave={handleDragLeave}
          onDrop={handleDrop}
          onClick={openInput}
        >
          <input
            accept="image/png, image/jpeg"
            style={{ display: "none" }}
            type="file"
            id="artwork-upload"
            ref={inputRef}
            onChange={handleChange}
          />
          <UploadFileRounded
            sx={{
              color: dragHovering
                ? theme.palette.primary.dark
                : theme.palette.primary.main,
            }}
          />
        </div>
      );
  }
}
