import { useEffect, useRef } from "react";
import {
  StarRounded,
  ArrowUpwardRounded,
  VolumeUpRounded,
} from "@mui/icons-material";

export interface IconWidths {
  star: number;
  upwardArrow: number;
  volumeUp: number;
}

interface MeasureIconWidthsProps {
  setIconWidths: (iconWidhts: IconWidths) => void;
}

export const MeasureIconWidths = ({
  setIconWidths,
}: MeasureIconWidthsProps) => {
  const containerRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const container = containerRef.current;

    if (container) {
      const childrenWidths = Array.from(container.children).map(
        (child) => child.getBoundingClientRect().width
      );
      setIconWidths({
        star: childrenWidths[0],
        upwardArrow: childrenWidths[1],
        volumeUp: childrenWidths[2],
      });
    }
  }, [setIconWidths]);

  return (
    <div
      ref={containerRef}
      style={{
        position: "absolute",
        visibility: "hidden",
        height: 0,
        overflow: "hidden",
      }}
    >
      <StarRounded fontSize="small" />
      <ArrowUpwardRounded fontSize="small" />
      <VolumeUpRounded fontSize="small" />
    </div>
  );
};
