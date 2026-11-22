import SwiftUI

struct PresetsView: View {
    @EnvironmentObject var library: EffectLibrary
    @EnvironmentObject var player: EffectPlayer
    @EnvironmentObject var carMaps: CarMapStore
    @Binding var section: MainSection
    @State private var editingPlaylist: Playlist?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Card(title: "Pacchetto animazioni A1", systemImage: "film.stack") {
                    NavigationLink { ClipLibraryView() } label: {
                        Label("60 animazioni adattive", systemImage: "sparkles").font(.subheadline.weight(.semibold))
                    }
                    Text("Calcolate sulla posizione e sulla zona di ogni LED della mappa attiva: dopo la scansione seguono i LED veri. Velocità, intensità e colore regolabili.")
                        .font(.caption2).foregroundStyle(Theme.textSecondary)
                }
                Card(title: "Effetti salvati", systemImage: "wand.and.stars") {
                    if library.programs.isEmpty {
                        Text("Salva un effetto dallo Studio Effetti (icona di salvataggio).").font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(library.programs) { p in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(.subheadline.weight(.semibold))
                                Text(p.layers.map { $0.params.kind.label }.joined(separator: " + ") + (p.paint.isEmpty ? "" : " + \(p.paint.count) pixel dipinti"))
                                    .font(.caption2).foregroundStyle(Theme.textSecondary).lineLimit(1)
                            }
                            Spacer()
                            Button { player.play(p) } label: { Image(systemName: "play.circle.fill").font(.title2) }
                                .disabled(carMaps.active == nil)
                            Button { player.update(p); player.play(p); section = .effects } label: { Image(systemName: "slider.horizontal.3") }
                            Button(role: .destructive) { library.deleteProgram(p.id) } label: { Image(systemName: "trash") }
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                Card(title: "Playlist", systemImage: "list.bullet.rectangle") {
                    ForEach(library.playlists) { pl in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pl.name).font(.subheadline.weight(.semibold))
                                Text("\(pl.items.count) effetti · \(Int(pl.items.reduce(0) { $0 + $1.seconds })) s")
                                    .font(.caption2).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            if player.isPlaying && player.playlist?.id == pl.id {
                                Text("▶︎ \(player.playlistIndex + 1)/\(pl.items.count)").font(Theme.monoSmall).foregroundStyle(Theme.ok)
                            }
                            Button { player.play(pl) } label: { Image(systemName: "play.circle.fill").font(.title2) }
                                .disabled(pl.items.isEmpty || carMaps.active == nil)
                            Button { editingPlaylist = pl } label: { Image(systemName: "pencil") }
                            Button(role: .destructive) { library.deletePlaylist(pl.id) } label: { Image(systemName: "trash") }
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Button { editingPlaylist = Playlist(name: "Playlist \(library.playlists.count + 1)", items: []) } label: {
                        Label("Nuova playlist", systemImage: "plus")
                    }
                    .buttonStyle(AccentButtonStyle(filled: false))
                    .enabled(!library.programs.isEmpty)
                    Text("La playlist usa la modalità scelta nello Studio Effetti (Anteprima o Live).").font(.caption2).foregroundStyle(Theme.textSecondary)
                }
                if player.isPlaying {
                    Button { player.stop() } label: { Label("Ferma riproduzione", systemImage: "stop.fill") }
                        .buttonStyle(AccentButtonStyle(color: Theme.danger, filled: false))
                }
                Card(title: "Disegni 2D", systemImage: "square.grid.4x3.fill") {
                    NavigationLink { EditorView() } label: { Label("Editor 2D e preset della singola centralina", systemImage: "paintbrush.pointed") }
                    Text("Strumenti della prima versione, collegati tramite il Bluetooth Lab.").font(.caption2).foregroundStyle(Theme.textSecondary)
                }
            }
            .padding()
        }
        .screenBackground()
        .navigationTitle("Preset")
        .sheet(item: $editingPlaylist) { pl in PlaylistEditor(playlist: pl) }
    }
}

struct PlaylistEditor: View {
    @EnvironmentObject var library: EffectLibrary
    @Environment(\.dismiss) private var dismiss
    @State var playlist: Playlist

    var body: some View {
        NavigationStack {
            Form {
                TextField("Nome", text: $playlist.name)
                Section("Sequenza") {
                    ForEach($playlist.items) { $item in
                        VStack(alignment: .leading) {
                            Text(library.program(item.programID)?.name ?? "Effetto eliminato")
                            Stepper("Durata: \(Int(item.seconds)) s", value: $item.seconds, in: 2...600, step: 1)
                        }
                    }
                    .onDelete { playlist.items.remove(atOffsets: $0) }
                    .onMove { playlist.items.move(fromOffsets: $0, toOffset: $1) }
                }
                Section("Aggiungi") {
                    ForEach(library.programs) { p in
                        Button { playlist.items.append(Playlist.Item(programID: p.id, seconds: 15)) } label: {
                            Label(p.name, systemImage: "plus.circle")
                        }
                    }
                }
            }
            .navigationTitle("Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Salva") { library.save(playlist); dismiss() } }
                ToolbarItem(placement: .bottomBar) { EditButton() }
            }
        }
        .preferredColorScheme(.dark)
    }
}
