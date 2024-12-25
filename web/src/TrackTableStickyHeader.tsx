import { forwardRef, useContext, CSSProperties } from "react";
import { TrackTableContext } from "./TrackTableContext";
import { TrackTableHeaderCell } from "./TrackTableHeaderCell";
import { COLUMNS } from "./TrackTableColumns";
import { HEADER_HEIGHT } from "./TrackTableConstants";

// much of this is based on https://codesandbox.io/p/sandbox/sticky-variable-grid-example-0cnwb
interface RenderedColumnRange {
  min: number;
  max: number;
}

function GetRenderedColumnRange(children: JSX.Element[]): RenderedColumnRange {
  const columnIndexes = children.map((child) => child.props.columnIndex);
  return { min: Math.min(...columnIndexes), max: Math.max(...columnIndexes) };
}

interface HeaderColumnStyle {
  height: number;
  width: number;
  left: number;
}

const GetHeaderColumnStyles = (
  minColumn: number,
  maxColumn: number,
  columnWidth: (idx: number) => number
): HeaderColumnStyle[] => {
  const columns = [];
  const left = [0];
  let pos = 0;

  for (let c = 1; c <= maxColumn; c++) {
    pos += columnWidth(c - 1);
    left.push(pos);
  }

  for (let i = minColumn; i <= maxColumn; i++) {
    columns.push({
      height: HEADER_HEIGHT,
      width: columnWidth(i),
      left: left[i],
    });
  }

  return columns;
};

interface StickyHeaderProps {
  headerStyles: HeaderColumnStyle[];
}

const StickyHeader = ({ headerStyles }: StickyHeaderProps) => {
  const context = useContext(TrackTableContext);

  return (
    <div
      style={{
        position: "sticky",
        top: 0,
        left: 0,
        display: "flex",
        flexDirection: "row",
        zIndex: 3,
      }}
    >
      <div style={{ position: "absolute", left: 0 }}>
        {headerStyles.map((style, i: number) => (
          <TrackTableHeaderCell
            column={COLUMNS[i]}
            sortState={context.sortState}
            style={style}
            setSortState={context.setSortState}
            label={COLUMNS[i].label}
            key={i}
          />
        ))}
      </div>
    </div>
  );
};

interface TrackTableStickyHeaderGridProps {
  children: JSX.Element[];
  style: { width: string; height: string };
}

export const TrackTableStickyHeaderGrid = forwardRef<
  HTMLDivElement,
  TrackTableStickyHeaderGridProps
>(({ children, style }: TrackTableStickyHeaderGridProps, ref) => {
  const context = useContext(TrackTableContext);
  const { min: minColumn, max: maxColumn } = GetRenderedColumnRange(children);

  const headerStyles = GetHeaderColumnStyles(
    minColumn,
    maxColumn,
    (i) => context.columnWidths[i]
  );
  const containerStyle: CSSProperties = {
    ...style,
    position: "absolute",
    width: `${parseFloat(style!.width)}px`,
    height: `${parseFloat(style!.height) + HEADER_HEIGHT}px`,
  };
  const containerProps = {
    style: containerStyle,
  };
  const gridDataContainerStyle: CSSProperties = {
    position: "absolute",
    top: HEADER_HEIGHT,
    left: 0,
  };

  return (
    <div ref={ref} {...containerProps}>
      <StickyHeader headerStyles={headerStyles} />
      <div style={gridDataContainerStyle}>{children}</div>
    </div>
  );
});
