import { isObject } from "lodash";

export const START_SYNC_TYPE = "startSync";
export const SYNC_SUCCEEDED_TYPE = "syncSucceeded";
export const SET_AUTH_TOKEN_TYPE = "setAuthToken";
export const FETCH_TRACK_TYPE = "fetchTrack";
export const TRACK_FETCHED_TYPE = "trackFetched";
export const FETCH_ARTWORK_TYPE = "fetchArtwork";
export const ARTWORK_FETCHED_TYPE = "artworkFetched";
export const CLEARED_ALL_TYPE = "clearedAll";
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

export interface FetchTrackMessage extends TypedMessage {
  trackId: string;
}

export type TrackFetchedMessage = FetchTrackMessage;

export interface FetchArtworkMessage extends TypedMessage {
  artworkId: string;
}

export type ArtworkFetchedMessage = FetchArtworkMessage;

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

export function isFetchTrackMessage(
  message: TypedMessage
): message is FetchTrackMessage {
  return (
    isObject(message) &&
    message.type === FETCH_TRACK_TYPE &&
    "trackId" in message
  );
}

export function isTrackFetchedMessage(
  message: TypedMessage
): message is TrackFetchedMessage {
  return (
    isObject(message) &&
    message.type === TRACK_FETCHED_TYPE &&
    "trackId" in message
  );
}

export function isFetchArtworkMessage(
  message: TypedMessage
): message is FetchArtworkMessage {
  return (
    isObject(message) &&
    message.type === FETCH_ARTWORK_TYPE &&
    "artworkId" in message
  );
}

export function isArtworkFetchedMessage(
  message: TypedMessage
): message is ArtworkFetchedMessage {
  return (
    isObject(message) &&
    message.type === ARTWORK_FETCHED_TYPE &&
    "artworkId" in message
  );
}

export function isClearedAllMessage(message: TypedMessage) {
  return isObject(message) && message.type === CLEARED_ALL_TYPE;
}

export function isErrorMessage(message: TypedMessage): message is ErrorMessage {
  return isObject(message) && message.type === ERROR_TYPE && "error" in message;
}
