export type StringKeys<T> = {
  [K in keyof T]: T[K] extends string ? K : never;
}[keyof T];

export function circularArraySlice<T>(
  array: T[],
  index: number,
  count: number = 3
): T[] {
  if (array.length <= count) {
    return [...array];
  }

  const result: T[] = [];
  for (let i = 0; i < count; i++) {
    result.push(array[(index + i) % array.length]);
  }
  return result;
}

export function formatBytes(bytes: number, decimals = 2) {
  if (!bytes) {
    return "0b";
  }
  const k = 1024;
  const sizes = ["b", "kb", "mb", "gb", "tb"];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return `${parseFloat((bytes / Math.pow(k, i)).toFixed(decimals))} ${
    sizes[i]
  }`;
}

export function formatTimestamp(time: number): string {
  const date = new Date(time);
  const now = new Date();

  const isSameDay =
    date.getFullYear() === now.getFullYear() &&
    date.getMonth() === now.getMonth() &&
    date.getDate() === now.getDate();

  const timeFormatter = new Intl.DateTimeFormat(undefined, {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    fractionalSecondDigits: 3,
    hour12: true,
  });

  const timeString = timeFormatter.format(date);

  if (isSameDay) {
    return timeString;
  }

  const dateFormatter = new Intl.DateTimeFormat(undefined, {
    month: "2-digit",
    day: "2-digit",
  });

  return `${dateFormatter.format(date)} ${timeString}`;
}
