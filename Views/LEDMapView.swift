import SwiftUI
import UIKit

struct LEDMapView: View {
    @EnvironmentObject var maps: LEDMapStore
    @EnvironmentObject var settings: AppSettings
    @State private var shareItem: ShareItem?
    @State private var exportError: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                overviewCard
                if maps.sections.isEmpty {
                    Text("Nessuna mappa. Crea una sezione dalla schermata Scan.")
                        .font(.footnote).foregroundStyle(Theme.textSecondary).padding()
                }
                ForEach(maps.sections) { s in
                    NavigationLink {
                        SectionDetailView(sectionID: s.id)
                    } label: {
                        SectionRow(section: s, image: maps.image(for: s))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .screenBackground()
        .navigationTitle("LED Map")
        .toolbar {
            Button {
                do { shareItem = ShareItem(url: try maps.exportJSON()) } catch { exportError = error.localizedDescription }
            } label: { Image(systemName: "square.and.arrow.up") }
                .disabled(maps.sections.isEmpty)
        }
        .sheet(item: $shareItem) { ActivityView(items: [$0.url]) }
    }

    private var overviewCard: some View {
        let n = settings.ledCount
        let cov = maps.coverage(ledCount: n)
        let missing = (0..<n).filter { cov[$0] == nil }
        return Card(title: "Mappa complessiva", systemImage: "map") {
            HStack {
                Text("Indici coperti").foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("\(cov.count) / \(n)").font(Theme.mono)
            }
            .font(.subheadline)
            // Barra di copertura per indice
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(0..<n, id: \.self) { i in
                        Rectangle().fill(cov[i] == nil ? Theme.surfaceHigh : Theme.accent)
                            .frame(width: geo.size.width / CGFloat(max(n, 1)))
                    }
                }
            }
            .frame(height: 10)
            .clipShape(Capsule())
            if !missing.isEmpty {
                Text("Mancanti: " + IndexRanges.text(missing)).font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Text("Unione per indice delle sezioni salvate. Ogni sezione resta una proiezione 2D della sua inquadratura: la ricostruzione 3D richiederebbe più viste calibrate.")
                .font(.caption2).foregroundStyle(Theme.textSecondary)
            if let exportError { Text(exportError).font(.caption).foregroundStyle(Theme.danger) }
        }
    }
}

struct SectionRow: View {
    let section: LEDMapSection
    let image: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Theme.surfaceHigh
                }
            }
            .frame(width: 56, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text(section.name).font(.subheadline.weight(.semibold))
                let s = section.summary
                Text("\(s.uniqueIndices) indici · \(s.points) punti · \(s.missing.count) mancanti")
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                Text(section.createdAt, style: .date).font(.caption2).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(Theme.textSecondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
    }
}

/// Dettaglio di una sezione con correzione manuale: tocca un punto per selezionarlo,
/// cambia o rimuovi l'indice, aggiungi punti mancanti, accendi l'indice per verificarlo.
struct SectionDetailView: View {
    @EnvironmentObject var maps: LEDMapStore
    @EnvironmentObject var ideal: IdealController
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    let sectionID: UUID

    @State private var draft: LEDMapSection?
    @State private var selected: UUID?
    @State private var addMode = false
    @State private var showLabels = true
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            if let draft {
                VStack(spacing: 14) {
                    imageCard(draft)
                    editCard(draft)
                    statsCard(draft)
                }
                .padding()
            }
        }
        .screenBackground()
        .navigationTitle(draft?.name ?? "Sezione")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                Toggle("Mostra indici", isOn: $showLabels)
                Button("Elimina sezione", role: .destructive) { confirmDelete = true }
            } label: { Image(systemName: "ellipsis.circle") }
        }
        .onAppear { draft = maps.sections.first { $0.id == sectionID } }
        .confirmationDialog("Eliminare questa sezione?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Elimina", role: .destructive) {
                if let d = draft { maps.delete(d) }
                dismiss()
            }
        }
    }

    private func imageCard(_ s: LEDMapSection) -> some View {
        Card {
            ZStack {
                if let img = maps.image(for: s) {
                    Image(uiImage: img).resizable().scaledToFit()
                } else {
                    Rectangle().fill(Color.black)
                }
                PointsOverlay(points: s.points, selected: selected, showLabels: showLabels)
            }
            .aspectRatio(s.aspect, contentMode: .fit)
            .overlay(
                GeometryReader { geo in
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { loc in tap(loc, size: geo.size) }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            Toggle("Tocca per aggiungere un punto", isOn: $addMode).font(.subheadline)
        }
    }

    @ViewBuilder
    private func editCard(_ s: LEDMapSection) -> some View {
        if let id = selected, let i = s.points.firstIndex(where: { $0.id == id }) {
            let p = s.points[i]
            Card(title: "Punto selezionato", systemImage: "scope") {
                HStack {
                    Text(p.index.map { "Indice \($0)" } ?? "Senza indice").font(.headline)
                    Spacer()
                    Text(String(format: "conf. %.2f", p.confidence)).font(Theme.monoSmall).foregroundStyle(Theme.textSecondary)
                }
                Stepper("Cambia indice", onIncrement: { setIndex(at: i, (p.index ?? -1) + 1) },
                        onDecrement: { setIndex(at: i, (p.index ?? 1) - 1) })
                HStack(spacing: 10) {
                    Button("Accendi") { light(p.index) }
                        .buttonStyle(AccentButtonStyle(filled: false))
                        .enabled(p.index != nil && ideal.canDraw)
                    Button("Togli indice") { setIndex(at: i, nil) }
                        .buttonStyle(AccentButtonStyle(color: Theme.warning, filled: false))
                    Button("Elimina") { removePoint(at: i) }
                        .buttonStyle(AccentButtonStyle(color: Theme.danger, filled: false))
                }
                Text("\"Accendi\" illumina solo questo indice (DOOD) per controllare sull'oggetto reale.")
                    .font(.caption2).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func statsCard(_ s: LEDMapSection) -> some View {
        let sum = s.summary
        return Card(title: "Riepilogo", systemImage: "chart.bar") {
            Text("\(sum.points) punti · \(sum.decoded) con indice · \(sum.uniqueIndices) indici distinti · \(sum.duplicatedIndices) doppi (Y)")
                .font(.caption)
            if sum.conflicts > 0 {
                Text("\(sum.conflicts) indici compaiono più di due volte: controllali.").font(.caption).foregroundStyle(Theme.warning)
            }
            if !sum.missing.isEmpty {
                Text("Mancanti: " + IndexRanges.text(sum.missing)).font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Text("Rosso = senza indice · arancione = corretto a mano · cyan = rilevato.")
                .font(.caption2).foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: Modifiche

    private func tap(_ loc: CGPoint, size: CGSize) {
        guard var d = draft, size.width > 0, size.height > 0 else { return }
        let nx = Double(loc.x / size.width), ny = Double(loc.y / size.height)
        let nearest = d.points.enumerated().min { a, b in
            hypot((a.element.x - nx) * Double(size.width), (a.element.y - ny) * Double(size.height))
                < hypot((b.element.x - nx) * Double(size.width), (b.element.y - ny) * Double(size.height))
        }
        if let n = nearest,
           hypot((n.element.x - nx) * Double(size.width), (n.element.y - ny) * Double(size.height)) < 22 {
            selected = n.element.id
            return
        }
        guard addMode else { selected = nil; return }
        let missing = d.summary.missing
        let p = MappedPoint(index: missing.first, x: nx, y: ny, confidence: 1, area: 0, manual: true)
        d.points.append(p)
        commit(d)
        selected = p.id
    }

    private func setIndex(at i: Int, _ value: Int?) {
        guard var d = draft, d.points.indices.contains(i) else { return }
        if let v = value {
            d.points[i].index = min(max(v, 0), d.ledCount - 1)
        } else {
            d.points[i].index = nil
        }
        d.points[i].manual = true
        commit(d)
    }

    private func removePoint(at i: Int) {
        guard var d = draft, d.points.indices.contains(i) else { return }
        d.points.remove(at: i)
        selected = nil
        commit(d)
    }

    private func commit(_ d: LEDMapSection) {
        draft = d
        maps.update(d)
    }

    private func light(_ index: Int?) {
        guard let index else { return }
        var target = [RGB](repeating: .black, count: min(settings.ledCount, IdealProtocol.maxSafeLEDs))
        if target.indices.contains(index) { target[index] = RGB(r: 255, g: 255, b: 255) }
        ideal.apply(target: target)
    }
}
