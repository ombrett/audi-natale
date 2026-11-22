import SwiftUI

/// Schermate delle milestone 3 e 4. Non simulano funzioni non ancora implementate:
/// mostrano cosa faranno e da cosa dipendono.
struct PlannedScreen: View {
    let title: String
    let milestone: String
    let systemImage: String
    let summary: String
    let steps: [String]
    let dependency: String

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Card(title: "Milestone \(milestone) — non implementata", systemImage: systemImage) {
                    Text(summary).font(.subheadline)
                    Label(dependency, systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                }
                Card(title: "Previsto", systemImage: "list.number") {
                    ForEach(Array(steps.enumerated()), id: \.offset) { i, s in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(i + 1)").font(.caption.weight(.bold)).foregroundStyle(Theme.accent).frame(width: 18)
                            Text(s).font(.caption)
                        }
                    }
                }
            }
            .padding()
        }
        .screenBackground()
        .navigationTitle(title)
    }
}

struct ScanView: View {
    var body: some View {
        PlannedScreen(
            title: "Scan", milestone: "3", systemImage: "camera.viewfinder",
            summary: "Mappatura automatica: la fotocamera inquadra una sezione dell'auto mentre l'app accende sequenze controllate di LED e ne ricava le posizioni.",
            steps: [
                "Selezione della sezione dell'auto e del controller.",
                "Fotogrammi di riferimento tutto spento / tutto acceso per soglie e riflessi.",
                "Codifica binaria degli indici: 11 bit per 1600 LED più bit di parità e ripetizioni, con pattern e complementi (non bastano 11 foto).",
                "Attesa dell'ack DOOT/DOOD e compensazione della latenza BLE prima di ogni scatto.",
                "Rilevamento dei blob con Vision/CoreImage e associazione all'indice.",
                "Mappa 2D per inquadratura, correzione manuale, unione delle sezioni.",
            ],
            dependency: "Richiede il controllo verificato di più pixel (Milestone 2)."
        )
        .toolbar { NavigationLink("LED Map") { LEDMapView() } }
    }
}

struct LEDMapView: View {
    var body: some View {
        PlannedScreen(
            title: "LED Map", milestone: "3", systemImage: "point.3.connected.trianglepath.dotted",
            summary: "Mappe 2D per inquadratura e mappa complessiva. Una ricostruzione 3D richiederà più viste calibrate: con una sola vista la mappa resta una proiezione 2D e verrà indicata così.",
            steps: [
                "Mappa per sezione con coordinate normalizzate e confidenza per LED.",
                "Editor di correzione: sposta, scambia, segna come non visibile.",
                "Unione delle sezioni nella disposizione complessiva dell'auto.",
                "Indice globale = (controller, indice locale) per installazioni con più centraline.",
            ],
            dependency: "Richiede la scansione (Milestone 3)."
        )
    }
}

struct EditorView: View {
    var body: some View {
        PlannedScreen(
            title: "Editor", milestone: "4", systemImage: "paintbrush.pointed",
            summary: "Editor LED su vista 2D: pennello, gomma, riempimento, colori, luminosità, testo, disegni, anteprima, preset, più centraline.",
            steps: [
                "Stato pixel per controller con limite di sicurezza a 400 LED ciascuno finché il firmware 23.09.12.1 non è analizzato.",
                "Invio dei disegni con DOOT (run di colori, 14 record per frame) e verifica di ogni ack DOOTREOK.",
                "Aggiornamenti singoli con DOOD per le modifiche piccole.",
                "Preset salvati in locale.",
            ],
            dependency: "Richiede il trasferimento dei disegni verificato (Milestone 2)."
        )
        .toolbar { NavigationLink("Animations") { AnimationsView() } }
    }
}

struct AnimationsView: View {
    var body: some View {
        PlannedScreen(
            title: "Animations", milestone: "4", systemImage: "sparkles",
            summary: "Animazioni generate dall'app con frequenza limitata alla velocità reale misurata del collegamento BLE, mostrata a schermo.",
            steps: [
                "Misura dei tempi di upload e degli ack su ogni controller.",
                "Limite automatico dei fotogrammi al secondo.",
                "Effetti nativi del controller (SGLS/MULT) dove bastano.",
            ],
            dependency: "Richiede l'editor (Milestone 4)."
        )
    }
}
