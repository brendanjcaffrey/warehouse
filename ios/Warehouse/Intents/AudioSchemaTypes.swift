import AppIntents

@available(iOS 27.0, *)
@AppEnum(schema: .audio.playbackAttributes)
enum WarehousePlaybackAttribute: String {
    case shuffle
    case `repeat`

    static let caseDisplayRepresentations: [WarehousePlaybackAttribute: DisplayRepresentation] = [
        .shuffle: "Shuffle",
        .repeat: "Repeat"
    ]
}

@available(iOS 27.0, *)
@AppEnum(schema: .audio.queueInsertionLocation)
enum WarehouseQueueInsertionLocation: String {
    case next
    case tail

    static let caseDisplayRepresentations: [WarehouseQueueInsertionLocation: DisplayRepresentation] = [
        .next: "Next",
        .tail: "Last"
    ]
}

@available(iOS 27.0, *)
@AppEntity(schema: .audio.warmupAudioQueueResult)
struct WarehouseWarmupAudioQueueResult: TransientAppEntity {
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Ready to Play")
    }
}
