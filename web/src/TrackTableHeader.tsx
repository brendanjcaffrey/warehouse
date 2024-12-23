import { ArrowDownwardRounded, ArrowUpwardRounded } from "@mui/icons-material";
import { COLUMNS } from "./TrackTableColumns";
import { darkerGrey } from "./Colors";
import {
  HEADER_HEIGHT,
  CELL_HORIZONTAL_PADDING_SIDE,
} from "./TrackTableConstants";

interface TrackTableHeaderProps {
  columnWidths: number[];
}

function TrackTableHeader({ columnWidths }: TrackTableHeaderProps) {
  return (
    <div style={{ overflow: "visible", height: HEADER_HEIGHT, width: 0 }}>
      <div
        style={{
          position: "relative",
          height: 0,
          width: 0,
        }}
      >
        {COLUMNS.map((column) => (
          <div
            key={column.id}
            style={{
              position: "absolute",
              top: 0,
              left: columnWidths
                .slice(0, COLUMNS.indexOf(column))
                .reduce((x, y) => x + y, 0),
              width: columnWidths[COLUMNS.indexOf(column)],
              height: HEADER_HEIGHT - 1, // give a pixel back for the border
              padding: `0 ${CELL_HORIZONTAL_PADDING_SIDE}px`,
              borderBottom: "1px solid black",
              fontWeight: "bold",
              cursor: "pointer",
            }}
            className="has-sort-icon valign-center"
          >
            {column.label}
            <ArrowUpwardRounded
              fontSize="small"
              className="hover-only"
              style={{ color: darkerGrey }}
            />
          </div>
        ))}
      </div>
    </div>
  );
}

export default TrackTableHeader;
