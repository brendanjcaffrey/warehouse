import { useState, useEffect } from "react";
import { useSetAtom } from "jotai";
import { typeToShowInProgressAtom } from "./State";

const TYPE_TO_SHOW_ALPHABET =
  "abcdefghijklmnopqrstuvwxyz0123456789.()- '".split("");
const TYPE_TO_SHOW_DELAY_MILLIS = 750;

export function useDebouncedTypeToShowInput(
  callback: (typedInput: string) => void
) {
  const [typedInput, setTypedInput] = useState("");
  const setTypeToShowInProgress = useSetAtom(typeToShowInProgressAtom);

  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if (
        event.target instanceof HTMLInputElement ||
        !TYPE_TO_SHOW_ALPHABET.includes(event.key) ||
        event.altKey ||
        event.ctrlKey ||
        event.metaKey
      ) {
        return;
      }
      event.preventDefault();
      setTypedInput((prev) => prev + event.key);
    };

    document.addEventListener("keydown", handleKeyDown);
    return () => {
      document.removeEventListener("keydown", handleKeyDown);
    };
  }, []);

  useEffect(() => {
    if (typedInput === "") return;

    // if the typed input is only a space, then ignore
    if (typedInput === " ") {
      setTypedInput("");
      setTypeToShowInProgress(false);
      return;
    }

    setTypeToShowInProgress(true);
    const timeoutId = setTimeout(() => {
      callback(typedInput);
      setTypedInput("");
      setTypeToShowInProgress(false);
    }, TYPE_TO_SHOW_DELAY_MILLIS);

    return () => {
      clearTimeout(timeoutId);
    };
  }, [typedInput, setTypeToShowInProgress, callback]);
}
