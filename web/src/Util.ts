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
