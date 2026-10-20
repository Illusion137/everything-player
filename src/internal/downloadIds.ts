const live = new Set<string>()

export function markDownloadLive(trackId: string, isLive: boolean): void {
  if (isLive) live.add(trackId)
  else live.delete(trackId)
}

export function liveDownloadTrackIds(): Iterable<string> {
  return live
}
