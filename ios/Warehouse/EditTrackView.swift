import PhotosUI
import SwiftUI

/// form for editing a track's metadata & artwork, presented as a sheet;
/// mirrors the web app's edit track panel: only changed fields are submitted,
/// the edit is applied locally right away & queued for the server
struct EditTrackView: View {
    @Environment(SongsStore.self) private var songs
    @Environment(PlayerStore.self) private var player
    @Environment(UpdatesStore.self) private var updates
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    let song: Song

    @State private var form: TrackEditForm
    @State private var pickedItem: PhotosPickerItem?
    @State private var pickedArtworkData: Data?
    @State private var errorMessage: String?
    @State private var saving = false
    @State private var canPasteArtwork = false

    init(song: Song) {
        self.song = song
        _form = State(initialValue: TrackEditForm(song: song))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    field("Name", text: $form.name, valid: form.isNameValid, id: "editName")
                    field("Artist", text: $form.artist, valid: form.isArtistValid, id: "editArtist")
                    field("Album", text: $form.album, valid: true, id: "editAlbum")
                    field("Album Artist", text: $form.albumArtist, valid: true, id: "editAlbumArtist")
                    field("Genre", text: $form.genre, valid: form.isGenreValid, id: "editGenre")
                    field("Year", text: $form.year, valid: form.isYearValid, id: "editYear")
                        .keyboardType(.numberPad)
                }
                Section {
                    field(
                        "Start", text: $form.start,
                        valid: form.isStartValid(duration: song.duration), id: "editStart")
                        .keyboardType(.numbersAndPunctuation)
                        .monospacedDigit()
                    field(
                        "Finish", text: $form.finish,
                        valid: form.isFinishValid(duration: song.duration), id: "editFinish")
                        .keyboardType(.numbersAndPunctuation)
                        .monospacedDigit()
                }
                Section {
                    HStack {
                        Text("Rating")
                        Spacer()
                        StarRating(stars: $form.rating)
                            .accessibilityIdentifier("editRating")
                    }
                    HStack {
                        Text("Play Count")
                        Spacer()
                        Text("\(song.playCount)")
                            .foregroundStyle(.secondary)
                    }
                }
                artworkSection
            }
            .navigationTitle("Edit Track")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(saving || !form.isValid(duration: song.duration))
                    .accessibilityIdentifier("editSave")
                }
            }
            .alert("Couldn't Save", isPresented: showingError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .onChange(of: pickedItem) {
            loadPickedArtwork()
        }
        .onAppear { canPasteArtwork = ArtworkPasteboard.hasImage() }
        .onChange(of: scenePhase) {
            // re-check the clipboard after copying an image in another app
            if scenePhase == .active { canPasteArtwork = ArtworkPasteboard.hasImage() }
        }
    }

    private var showingError: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } })
    }

    private func field(_ label: String, text: Binding<String>, valid: Bool, id: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(valid ? Color.primary : Color.red)
            TextField(label, text: text)
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(id)
        }
    }

    private var artworkSection: some View {
        Section("Artwork") {
            HStack(spacing: 16) {
                artworkPreview
                    .frame(width: 80, height: 80)
                    .contextMenu { artworkMenu }
                VStack(alignment: .leading, spacing: 12) {
                    PhotosPicker("Choose Artwork", selection: $pickedItem, matching: .images)
                    if hasArtwork {
                        Button("Remove Artwork", role: .destructive) {
                            pickedItem = nil
                            pickedArtworkData = nil
                            form.artworkCleared = true
                        }
                    }
                }
                .buttonStyle(.borderless)
                .font(.subheadline)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var artworkPreview: some View {
        if let pickedArtworkData, let image = UIImage(data: pickedArtworkData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else if form.artworkCleared {
            ArtworkThumbnail(url: nil)
        } else {
            ArtworkThumbnail(url: songs.artworkURL(filename: song.artworkFilename), maxPixelSize: 240)
        }
    }

    private var hasArtwork: Bool {
        pickedArtworkData != nil || (!form.artworkCleared && song.artworkFilename != nil)
    }

    @ViewBuilder
    private var artworkMenu: some View {
        if hasArtwork {
            Button("Copy", systemImage: "doc.on.doc") { copyArtwork() }
        }
        if canPasteArtwork {
            Button("Paste", systemImage: "doc.on.clipboard") { pasteArtwork() }
        }
    }

    private func copyArtwork() {
        let data = pickedArtworkData
            ?? songs.artworkURL(filename: song.artworkFilename).flatMap { try? Data(contentsOf: $0) }
        if let data {
            ArtworkPasteboard.copy(data)
        }
    }

    private func pasteArtwork() {
        guard let data = ArtworkPasteboard.imageData() else {
            errorMessage = "The pasted image couldn't be read."
            return
        }
        pickedItem = nil
        pickedArtworkData = data
        form.artworkCleared = false
    }

    private func loadPickedArtwork() {
        guard let pickedItem else { return }
        Task {
            if let data = try? await pickedItem.loadTransferable(type: Data.self) {
                pickedArtworkData = data
                form.artworkCleared = false
            } else {
                errorMessage = "The picked image couldn't be read."
            }
        }
    }

    /// applies the edit locally first so the ui updates instantly, then
    /// queues the server pushes: the artwork upload before the track info
    /// that references it, since the queue sends in order
    private func save() async {
        saving = true
        defer { saving = false }

        var uploadFilename: String?
        if let pickedArtworkData {
            do {
                let filename = try songs.storeArtwork(pickedArtworkData)
                form.artworkFilename = filename
                if filename != song.artworkFilename {
                    uploadFilename = filename
                }
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        let update = form.changedFields(from: song)
        guard update != TrackUpdate() else {
            dismiss()
            return
        }

        let updated = form.updatedSong(from: song)
        await songs.applyTrackEdit(updated)
        player.trackUpdated(updated)

        // the pushes go through the network, so don't hold the sheet open
        let updates = updates
        let trackId = song.id
        Task {
            if let uploadFilename {
                await updates.addArtworkUpload(filename: uploadFilename)
            }
            await updates.addTrackUpdate(trackId: trackId, update: update)
        }
        dismiss()
    }
}
