import { Track } from "./Library";
import { Column } from "./TrackTableColumns";

export interface TypeToShowEntry {
  trackIndex: number; // index into the original track list
  displayIndex: number; // row index in the table
  value: string;
}

export function BuildTypeToShowList(
  tracks: Track[],
  indexes: number[],
  column: Column
) {
  const typeToShowList: TypeToShowEntry[] = indexes.map(
    (trackIndex, displayIndex) => {
      return {
        trackIndex,
        displayIndex,
        value: tracks[trackIndex][column.id].toString().toLowerCase(),
      };
    }
  );

  return typeToShowList.sort((a, b) => {
    if (a.value < b.value) {
      return -1;
    } else if (a.value > b.value) {
      return 1;
    }
    return 0;
  });
}

export function BinarySearchTypeToShowList(
  typeToShowList: TypeToShowEntry[],
  searchStr: string
) {
  const binarySearchStep = (lower: number, upper: number): number => {
    if (lower > upper) {
      return lower;
    }

    const middle = Math.floor((lower + upper) / 2.0);
    const middleText = typeToShowList[middle].value.substring(
      0,
      searchStr.length
    );
    // go backwards, even if equal, to get first occurrence
    if (middleText >= searchStr) {
      upper = middle - 1;
    } else {
      lower = middle + 1;
    }

    return binarySearchStep(lower, upper);
  };

  const idx = binarySearchStep(0, typeToShowList.length - 1);
  if (idx === null) {
    return null;
  }
  return typeToShowList[idx];
}
