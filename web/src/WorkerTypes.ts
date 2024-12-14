import { isObject } from "lodash";

export const START_SYNC_TYPE = "startSync";
export const SYNC_SUCCEEDED_TYPE = "syncSucceeded";
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

export function isErrorMessage(message: TypedMessage): message is ErrorMessage {
  return isObject(message) && message.type === ERROR_TYPE && "error" in message;
}
