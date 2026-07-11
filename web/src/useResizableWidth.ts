import { SetStateAction, useRef, useState } from "react";
import { useAtom, WritableAtom } from "jotai";

type WidthAtom = WritableAtom<number, [SetStateAction<number>], void>;

// drives a horizontally resizable panel: the returned handle drags the width
// live and only persists to the atom on release, clamped to the allowed range
export function useResizableWidth(
  widthAtom: WidthAtom,
  clamp: (value: number) => number
) {
  const [width, setWidth] = useAtom(widthAtom);
  // tracks the width live during a drag so we only persist to the atom on release
  const [dragWidth, setDragWidth] = useState<number | null>(null);
  const containerRef = useRef<HTMLDivElement>(null);

  const displayWidth = dragWidth ?? width;

  const startResize = (event: React.MouseEvent) => {
    event.preventDefault();
    const left = containerRef.current?.getBoundingClientRect().left ?? 0;
    let latest = width;

    const onMove = (moveEvent: MouseEvent) => {
      latest = clamp(moveEvent.clientX - left);
      setDragWidth(latest);
    };
    const onUp = () => {
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", onUp);
      document.body.style.userSelect = "";
      document.body.style.cursor = "";
      setWidth(latest);
      setDragWidth(null);
    };

    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", onUp);
    document.body.style.userSelect = "none";
    document.body.style.cursor = "col-resize";
  };

  return { displayWidth, containerRef, startResize };
}
