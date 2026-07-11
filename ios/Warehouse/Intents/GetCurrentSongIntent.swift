import AppIntents

/// a building block for shortcuts automations, e.g. logging or sharing the
/// song that's playing
struct GetCurrentSongIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Current Song"
    static let description = IntentDescription("Returns the song that's currently playing.")

    @Dependency private var service: IntentPlaybackService

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<SongAppEntity?> {
        let entity = service.currentSong.map {
            SongAppEntity(song: $0, artworkURL: service.artworkURL(filename: $0.artworkFilename))
        }
        return .result(value: entity)
    }
}
