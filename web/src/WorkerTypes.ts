import { isObject } from "lodash";

export const START_SYNC_TYPE = "startSync";
export const SYNC_SUCCEEDED_TYPE = "syncSucceeded";
export const SET_AUTH_TOKEN_TYPE = "setAuthToken";
export const LIBRARY_METADATA_TYPE = "libraryMetadata";
export const KEEP_MODE_CHANGED_TYPE = "keepModeChanged";
export const SET_SOURCE_REQUESTED_FILES_TYPE = "setSourceRequestedFiles";
export const FILE_FETCHED_TYPE = "fileFetched";
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
}

export interface TypedMessage {
  type: string;
}

export interface AuthTokenMessage extends TypedMessage {
  authToken: string;
}

// eslint-disable-next-line @typescript-eslint/no-empty-object-type
export interface StartSyncMessage extends AuthTokenMessage {}

export interface ErrorMessage extends TypedMessage {
  error: string;
}

export interface LibraryMetadataMessage extends TypedMessage {
  trackUserChanges: boolean;
  totalFileSize: number;
}

export interface KeepModeChangedMessage extends TypedMessage {
  keepMode: boolean;
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

export function IsTypedMessage(message: object): message is TypedMessage {
  return isObject(message) && "type" in message;
}

export function IsStartSyncMessage(
  message: TypedMessage
): message is StartSyncMessage {
  return (
    isObject(message) &&
    message.type === START_SYNC_TYPE &&
    "authToken" in message
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

export function IsClearedAllMessage(message: TypedMessage) {
  return isObject(message) && message.type === CLEARED_ALL_TYPE;
}

export function IsErrorMessage(message: TypedMessage): message is ErrorMessage {
  return isObject(message) && message.type === ERROR_TYPE && "error" in message;
}
