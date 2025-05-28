export function FormatPlaybackPosition(time: number): string {
  const minutes = Math.floor(time / 60);
  const seconds = Math.floor(time % 60);
  return `${minutes}:${seconds < 10 ? "0" : ""}${seconds}`;
}

export function FormatPlaybackPositionWithMillis(time: number): string {
  const minutes = Math.floor(time / 60);
  const seconds = Math.floor(time % 60);
  const millis = Math.round((time % 1) * 1000);
  if (millis > 0) {
    let trimmedMillis = millis.toString().replace(/0+$/, "");
    if (millis < 10) {
      trimmedMillis = `0${trimmedMillis}`;
    }
    if (millis < 100) {
      trimmedMillis = `0${trimmedMillis}`;
    }
    return `${minutes}:${seconds < 10 ? "0" : ""}${seconds}.${trimmedMillis}`;
  } else {
    return `${minutes}:${seconds < 10 ? "0" : ""}${seconds}`;
  }
}

export function UnformatPlaybackPositionWithMillis(time: string): number {
  const parts = time.split(":");
  if (parts.length !== 2) {
    throw new Error("Invalid time format");
  }
  const minutes = parseInt(parts[0], 10);

  const secondsParts = parts[1].split(".");
  if (secondsParts.length !== 1 && secondsParts.length !== 2) {
    throw new Error("Invalid time format");
  }
  const seconds = parseInt(secondsParts[0], 10);
  let millis = 0;
  let millisDivisor = 1;
  if (secondsParts.length === 2 && secondsParts[1].length > 0) {
    millis = parseInt(secondsParts[1], 10);
    millisDivisor = Math.pow(10, secondsParts[1].length);
  }

  return minutes * 60 + seconds + millis / millisDivisor;
}
