import SwiftUI

/// "Altro": tutto ciò che non sta in Studio, Mappa 3D e Centraline, senza perdere nessuna funzione.
struct MoreView: View {
    var body: some View {
        List {
            Section {
                NavigationLink { ClipLibraryView() } label: { row("60 preset adattivi", "Libreria con anteprima 3D, velocità, intensità, colore unico", "sparkles") }
                NavigationLink { EffectsStudioView() } label: { row("Editor effetti", "Livelli, zone, selezione, pittura e gradienti sui LED", "slider.horizontal.3") }
                NavigationLink { PresetsView() } label: { row("Effetti salvati e playlist", "Riproduci, modifica, crea playlist", "list.bullet.rectangle") }
            } header: { Text("Effetti") }
            Section {
                NavigationLink { Scan3DView() } label: { row("Scansione 3D", "Mappatura AR delle centraline", "viewfinder") }
                NavigationLink { HomeView() } label: { row("Panoramica e flusso", "Stato impianto, copertura della mappa, passi guidati", "list.number") }
            } header: { Text("Mappatura") }
            Section {
                NavigationLink { SettingsView() } label: { row("Impostazioni e strumenti", "Invio, Bluetooth Lab, editor e scansione 2D, effetti interni, crediti", "gearshape") }
            } header: { Text("App") }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Altro")
    }

    private func row(_ title: String, _ subtitle: String, _ icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 24).foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Theme.textPrimary)
                Text(subtitle).font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.vertical, 2)
    }
}
