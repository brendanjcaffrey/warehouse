interface TrackFileIds {
  trackId: string;
  fileId: string;
}

export class TrackFileSet {
  private map: Map<string, TrackFileIds>;

  constructor() {
    this.map = new Map();
  }

  private getKey(obj: TrackFileIds): string {
    return `${obj.trackId}:${obj.fileId}`;
  }

  insert(obj: TrackFileIds): void {
    const key = this.getKey(obj);
    this.map.set(key, obj);
  }

  delete(obj: TrackFileIds): boolean {
    const key = this.getKey(obj);
    return this.map.delete(key);
  }

  has(obj: TrackFileIds): boolean {
    const key = this.getKey(obj);
    return this.map.has(key);
  }

  values(): TrackFileIds[] {
    return Array.from(this.map.values());
  }
}
