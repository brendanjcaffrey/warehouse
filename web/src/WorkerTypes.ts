import { isObject } from "lodash";

export const START_SYNC_TYPE = "startSync";
export const SYNC_SUCCEEDED_TYPE = "syncSucceeded";
export const SET_AUTH_TOKEN_TYPE = "setAuthToken";
export const LIBRARY_METADATA_TYPE = "libraryMetadata";
export const KEEP_MODE_CHANGED_TYPE = "keepModeChanged";
export const DOWNLOAD_MODE_CHANGED_TYPE = "downloadModeChanged";
export const SET_SOURCE_REQUESTED_FILES_TYPE = "setSourceRequestedFiles";
export const FILE_FETCHED_TYPE = "fileFetched";
export const FILE_DOWNLOAD_STATUS_TYPE = "fileDownloadStatus";
export const CLEARED_ALL_TYPE = "clearedAll";
export const ERROR_TYPE = "error";

export enum FileType {
  MUSIC,
  ARTWORK,
}

export enum FileRequestSource {
  MUSIC_DOWNLOAD,
  MUSIC_PRELOAD,
  ARTWORK_PRELOAD,
  DOWNLOAD_MODE_MUSIC,
  DOWNLOAD_MODE_ARTWORK,
}

export enum DownloadStatus {
  IN_PROGRESS,
  DONE,
  ERROR,
  CANCELED,
}

export interface TypedMessage {
  type: string;
}

export interface AuthTokenMessage extends TypedMessage {
  authToken: string;
}

export interface StartSyncMessage extends AuthTokenMessage {
  updateTimeNs: number;
  browserOnline: boolean;
}

export interface ErrorMessage extends TypedMessage {
  error: string;
}

export interface LibraryMetadataMessage extends TypedMessage {
  trackUserChanges: boolean;
  totalFileSize: number;
  updateTimeNs: number;
}

export interface KeepModeChangedMessage extends TypedMessage {
  keepMode: boolean;
}

export interface DownloadModeChangedMessage extends TypedMessage {
  downloadMode: boolean;
}

export interface TrackFileIds {
  trackId: string;
  fileId: string;
}

export interface SetSourceRequestedFilesMessage extends TypedMessage {
  source: FileRequestSource;
  fileType: FileType;
  ids: TrackFileIds[];
}

export interface FileFetchedMessage extends TypedMessage {
  fileType: FileType;
  ids: TrackFileIds;
}

export interface FileDownloadStatusMessage extends TypedMessage {
  ids: TrackFileIds;
  fileType: FileType;
  status: DownloadStatus;
  receivedBytes: number;
  totalBytes: number;
}

export function IsTypedMessage(message: object): message is TypedMessage {
  return isObject(message) && "type" in message;
}

export function IsStartSyncMessage(
  message: TypedMessage
): message is StartSyncMessage {
  return (
    isObject(message) &&
    message.type === START_SYNC_TYPE &&
    "authToken" in message &&
    "updateTimeNs" in message &&
    "browserOnline" in message
  );
}

export function IsSyncSucceededMessage(message: TypedMessage) {
  return isObject(message) && message.type === SYNC_SUCCEEDED_TYPE;
}

export function IsSetAuthTokenMessage(
  message: TypedMessage
): message is AuthTokenMessage {
  return (
    isObject(message) &&
    message.type === SET_AUTH_TOKEN_TYPE &&
    "authToken" in message
  );
}

export function IsLibraryMetadataMessage(
  message: TypedMessage
): message is LibraryMetadataMessage {
  return (
    isObject(message) &&
    message.type === LIBRARY_METADATA_TYPE &&
    "trackUserChanges" in message &&
    "totalFileSize" in message
  );
}

export function IsKeepModeChangedMessage(
  message: TypedMessage
): message is KeepModeChangedMessage {
  return (
    isObject(message) &&
    message.type === KEEP_MODE_CHANGED_TYPE &&
    "keepMode" in message
  );
}

export function IsDownloadModeChangedMessage(
  message: TypedMessage
): message is DownloadModeChangedMessage {
  return (
    isObject(message) &&
    message.type === DOWNLOAD_MODE_CHANGED_TYPE &&
    "downloadMode" in message
  );
}

export function IsSetSourceRequestedFilesMessage(
  message: TypedMessage
): message is SetSourceRequestedFilesMessage {
  return (
    isObject(message) &&
    message.type === SET_SOURCE_REQUESTED_FILES_TYPE &&
    "source" in message &&
    "fileType" in message &&
    "ids" in message
  );
}

export function IsFileFetchedMessage(
  message: TypedMessage
): message is FileFetchedMessage {
  return (
    isObject(message) && message.type === FILE_FETCHED_TYPE && "ids" in message
  );
}

export function IsFileDownloadStatusMessage(
  message: TypedMessage
): message is FileDownloadStatusMessage {
  return (
    isObject(message) &&
    message.type === FILE_DOWNLOAD_STATUS_TYPE &&
    "ids" in message &&
    "fileType" in message &&
    "status" in message &&
    "receivedBytes" in message &&
    "totalBytes" in message
  );
}

export function IsClearedAllMessage(message: TypedMessage) {
  return isObject(message) && message.type === CLEARED_ALL_TYPE;
}

export function IsErrorMessage(message: TypedMessage): message is ErrorMessage {
  return isObject(message) && message.type === ERROR_TYPE && "error" in message;
}
