import { useEffect, useRef } from "react";
import { StarRounded, ArrowUpwardRounded } from "@mui/icons-material";

export interface IconWidths {
  star: number;
  arrow: number;
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
      setIconWidths({ star: childrenWidths[0], arrow: childrenWidths[1] });
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
    </div>
  );
};
