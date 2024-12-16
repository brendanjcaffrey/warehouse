import { isObject } from "lodash";

export const START_SYNC_TYPE = "startSync";
export const SYNC_SUCCEEDED_TYPE = "syncSucceeded";
export const SET_AUTH_TOKEN_TYPE = "setAuthToken";
export const FETCH_ARTWORK_TYPE = "fetchArtwork";
export const ARTWORK_FETCHED_TYPE = "artworkFetched";
export const ERROR_TYPE = "error";

export interface TypedMessage {
  type: string;
}

export interface AuthTokenMessage extends TypedMessage {
  authToken: string;
}

export interface ErrorMessage extends TypedMessage {
  error: string;
}

export interface FetchArtworkMessage extends TypedMessage {
  artworkFilename: string;
}

export function isTypedMessage(message: object): message is TypedMessage {
  return isObject(message) && "type" in message;
}

export function isStartSyncMessage(
  message: TypedMessage
): message is AuthTokenMessage {
  return (
    isObject(message) &&
    message.type === START_SYNC_TYPE &&
    "authToken" in message
  );
}

export function isSyncSucceededMessage(message: TypedMessage) {
  return isObject(message) && message.type === SYNC_SUCCEEDED_TYPE;
}

export function isSetAuthTokenMessage(
  message: TypedMessage
): message is AuthTokenMessage {
  return (
    isObject(message) &&
    message.type === SET_AUTH_TOKEN_TYPE &&
    "authToken" in message
  );
}

export function IsFetchArtworkMessage(
  message: TypedMessage
): message is FetchArtworkMessage {
  return (
    isObject(message) &&
    message.type === FETCH_ARTWORK_TYPE &&
    "artworkFilename" in message
  );
}

export function isArtworkFetchedMessage(
  message: TypedMessage
): message is FetchArtworkMessage {
  return (
    isObject(message) &&
    message.type === ARTWORK_FETCHED_TYPE &&
    "artworkFilename" in message
  );
}

export function isErrorMessage(message: TypedMessage): message is ErrorMessage {
  return isObject(message) && message.type === ERROR_TYPE && "error" in message;
}
