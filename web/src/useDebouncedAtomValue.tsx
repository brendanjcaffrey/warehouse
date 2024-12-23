import { Atom, useAtomValue } from "jotai";
import { useEffect, useState } from "react";

export function useDebouncedAtomValue(atom: Atom<string>, delay = 300) {
  const value = useAtomValue(atom);
  const [debouncedValue, setDebouncedValue] = useState(value);

  useEffect(() => {
    const handler = setTimeout(() => {
      setDebouncedValue(value);
    }, delay);

    return () => {
      clearTimeout(handler);
    };
  }, [value, delay]);

  return debouncedValue;
}
