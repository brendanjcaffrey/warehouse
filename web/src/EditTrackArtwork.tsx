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
import { DownloadWorker } from "./DownloadWorker";
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
import { files } from "./Files";
import SparkMD5 from "spark-md5";
import { IMAGE_MIME_TO_EXTENSION } from "./MimeTypes";
import { updatePersister } from "./UpdatePersister";

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

function PostArtworkRequest(
  track: Track | undefined,
  artworkId: string | null
) {
  let preloadArtworkIds: TrackFileIds[] = [];
  if (track && artworkId) {
    preloadArtworkIds = [{ trackId: track.id, fileId: artworkId }];
  }
  DownloadWorker.postMessage({
    type: SET_SOURCE_REQUESTED_FILES_TYPE,
    source: FileRequestSource.EDIT_TRACK_ARTWORK,
    fileType: FileType.ARTWORK,
    ids: preloadArtworkIds,
  } as SetSourceRequestedFilesMessage);
}

async function TryStoreArtwork(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    if (!IMAGE_MIME_TO_EXTENSION.has(file.type)) {
      reject(new Error("invalid file type"));
    }

    const reader = new FileReader();

    reader.onload = async function (e) {
      if (e.target?.result instanceof ArrayBuffer) {
        const md5 = SparkMD5.ArrayBuffer.hash(e.target.result);
        const filename = `${md5}.${IMAGE_MIME_TO_EXTENSION.get(file.type)}`;
        if (await files().fileExists(FileType.ARTWORK, filename)) {
          resolve(filename);
        } else {
          const result = await files().tryWriteFile(
            FileType.ARTWORK,
            filename,
            e.target?.result
          );
          if (result) {
            updatePersister().uploadArtwork(filename);
            resolve(filename);
          } else {
            reject(new Error("Failed to write file"));
          }
        }
      } else {
        reject(new Error("Failed to read file as ArrayBuffer"));
      }
    };

    reader.onerror = function () {
      reject(new Error("FileReader error"));
    };

    reader.readAsArrayBuffer(file);
  });
}

interface EditTrackArtworkProps {
  track: Track | undefined;
  artworkCleared: boolean;
  setArtworkCleared: (cleared: boolean) => void;
  uploadedImageFilename: string | null;
  setUploadedImageFilename: (url: string | null) => void;
}

export function EditTrackArtwork({
  track,
  artworkCleared,
  setArtworkCleared,
  uploadedImageFilename,
  setUploadedImageFilename,
}: EditTrackArtworkProps) {
  const theme = useTheme();
  const artworkFileURL = useArtworkFileURL(track);
  const [artworkSelected, setArtworkSelected] = useState(false);
  const [uploadedImageFileURL, _setUploadedImageFileURL] = useState<
    string | null
  >(null);
  const setAndClearUploadedImageFileURL = useCallback(
    (v: string | null) => {
      _setUploadedImageFileURL((prev) => {
        if (prev) {
          URL.revokeObjectURL(prev);
        }
        return v;
      });
    },
    [_setUploadedImageFileURL]
  );

  useEffect(() => {
    setArtworkCleared(false);
    setArtworkSelected(false);
    setUploadedImageFilename(null);

    PostArtworkRequest(track, track?.artwork ?? null);
  }, [track, setArtworkCleared, setUploadedImageFilename]);

  useEffect(() => {
    if (uploadedImageFilename) {
      files()
        .tryGetFileURL(FileType.ARTWORK, uploadedImageFilename)
        .then((url) => {
          setAndClearUploadedImageFileURL(url);
        })
        .catch((error) => {
          console.error("Failed to get uploaded image URL:", error);
          setAndClearUploadedImageFileURL(null);
        });
    } else {
      setAndClearUploadedImageFileURL(null);
    }
  }, [uploadedImageFilename, setAndClearUploadedImageFileURL]);

  const clearOnDelete = useCallback(
    (event: KeyboardEvent) => {
      if (event.target instanceof HTMLInputElement) {
        return;
      }
      if (event.key !== "Backspace" && event.key !== "Delete") {
        return;
      }
      if (track && artworkSelected) {
        event.preventDefault();
        setArtworkSelected(false);
        setArtworkCleared(true);
        setUploadedImageFilename(null);
        PostArtworkRequest(track, null);
      }
    },
    [
      track,
      artworkSelected,
      setArtworkCleared,
      setUploadedImageFilename,
      setArtworkSelected,
    ]
  );

  useEffect(() => {
    document.addEventListener("keydown", clearOnDelete);
    return () => {
      document.removeEventListener("keydown", clearOnDelete);
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

  const handleFileChange = useCallback(
    async (file: File) => {
      if (file.size > MAX_FILE_SIZE) {
        enqueueSnackbar("File size exceeds 100 MB limit.", {
          variant: "error",
        });
        return;
      }
      const filename = await TryStoreArtwork(file);
      setUploadedImageFilename(filename);
      PostArtworkRequest(track, filename);
    },
    [setUploadedImageFilename, track]
  );

  const handleChange = useCallback(
    (event: ChangeEvent<HTMLInputElement>) => {
      const files = event.target.files;
      if (files && files[0]) {
        handleFileChange(files[0]);
      }
    },
    [handleFileChange]
  );

  const handleDrop = useCallback(
    (event: DragEvent) => {
      event.preventDefault();
      setDragHovering(false);
      const files = event.dataTransfer.files;
      if (files && files[0]) {
        handleFileChange(files[0]);
      }
    },
    [handleFileChange]
  );

  let artworkDisplayState = ArtworkDisplayState.NONE;
  if (track) {
    if (uploadedImageFileURL) {
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
            src={uploadedImageFileURL ?? artworkFileURL!}
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
            accept={Object.keys(IMAGE_MIME_TO_EXTENSION).join(", ")}
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
