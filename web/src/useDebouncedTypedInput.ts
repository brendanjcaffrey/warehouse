import { useState, useEffect } from "react";
import { player } from "./Player";

const ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789.()- '".split("");

export function useDebouncedTypedInput(
  callback: (typedInput: string) => void,
  delayMillis = 750
) {
  const [typedInput, setTypedInput] = useState("");

  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if (
        event.target instanceof HTMLInputElement ||
        !ALPHABET.includes(event.key) ||
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

    // this feels kind of shoe horned in here but whatever
    if (typedInput === " ") {
      player().playPause();
      setTypedInput("");
      return;
    }

    const timeoutId = setTimeout(() => {
      callback(typedInput);
      setTypedInput("");
    }, delayMillis);

    return () => {
      clearTimeout(timeoutId);
    };
  }, [typedInput, callback, delayMillis]);
}
