import Foundation

func ticksToMs(_ ticks: Int, _ timescale: Int, _ round: (Double) -> Double) -> Int {
    return Int(round((Double(ticks) / Double(timescale)) * 1000))
}

func getDurationMs(_ mediaHeader: MediaHeader) -> Int {
    let durationMsFromHeader = Int(mediaHeader.hasDurationMs ? mediaHeader.durationMs : 0)

    if durationMsFromHeader > 0 {
        return durationMsFromHeader
    }

    let durationTicks = Int(mediaHeader.timeRange.hasDurationTicks ? mediaHeader.timeRange.durationTicks : 0)
    let timescale = Int(mediaHeader.timeRange.hasTimescale ? mediaHeader.timeRange.timescale : 0)

    if durationTicks > 0 && timescale > 0 {
        return ticksToMs(durationTicks, timescale, ceil)
    }

    return 0
}

func getStartMs(_ mediaHeader: MediaHeader) -> Int {
    let startMsFromHeader = Int(mediaHeader.hasStartMs ? mediaHeader.startMs : 0)

    if startMsFromHeader > 0 {
        return startMsFromHeader
    }

    let startTicks = Int(mediaHeader.timeRange.hasStartTicks ? mediaHeader.timeRange.startTicks : 0)
    let timescale = Int(mediaHeader.timeRange.hasTimescale ? mediaHeader.timeRange.timescale : 0)

    if startTicks > 0 && timescale > 0 {
        return ticksToMs(startTicks, timescale, floor)
    }

    return 0
}
