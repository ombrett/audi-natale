import SwiftUI
import UIKit

struct LogSection: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "Tutto", tx = "TX", rx = "RX", events = "Eventi"
        var id: String { rawValue }
    }

    @EnvironmentObject var log: PacketLog
    @EnvironmentObject var ideal: IdealController
    @State private var filter: Filter = .all
    @State private var follow = true
    @State private var shareItem: ShareItem?
    @State private var toast: String?

    private var filtered: [PacketLogEntry] {
        switch filter {
        case .all: return log.entries
        case .tx: return log.entries.filter { $0.direction == .tx }
        case .rx: return log.entries.filter { $0.direction == .rx }
        case .events: return log.entries.filter { $0.direction != .tx && $0.direction != .rx }
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("Filtro", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle(isOn: $follow) { Image(systemName: "arrow.down.to.line") }
                    .toggleStyle(.button)
            }
            .padding(.horizontal)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(filtered) { e in
                            LogRow(entry: e).id(e.id)
                        }
                    }
                    .padding(.horizontal)
                }
                .onChange(of: log.entries.count) { _ in
                    guard follow, let last = filtered.last else { return }
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }

            HStack(spacing: 8) {
                Button { copy() } label: { Label("Copia", systemImage: "doc.on.doc") }
                Button { exportLog() } label: { Label("Esporta", systemImage: "square.and.arrow.up") }
                Button { exportDiagnostics() } label: { Label("Diagnostica", systemImage: "stethoscope") }
                Button(role: .destructive) { log.clear() } label: { Image(systemName: "trash") }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            .padding(.horizontal)
            .padding(.bottom, 8)

            if let toast {
                Text(toast).font(.caption).foregroundStyle(Theme.textSecondary).padding(.bottom, 4)
            }
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
        }
    }

    private func copy() {
        UIPasteboard.general.string = log.text(header: ideal.diagnosticsReport())
        flash("Log copiato negli appunti (\(log.entries.count) righe)")
    }

    private func exportLog() {
        do {
            let url = try log.export(header: ideal.diagnosticsReport())
            shareItem = ShareItem(url: url)
        } catch {
            flash("Esportazione fallita: \(error.localizedDescription)")
        }
    }

    private func exportDiagnostics() {
        do {
            let dir = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Logs", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("diagnostica-\(PacketLog.fileStamp()).txt")
            try ideal.diagnosticsReport().write(to: url, atomically: true, encoding: .utf8)
            shareItem = ShareItem(url: url)
        } catch {
            flash("Esportazione fallita: \(error.localizedDescription)")
        }
    }

    private func flash(_ s: String) {
        toast = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if toast == s { toast = nil } }
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct LogRow: View {
    let entry: PacketLogEntry

    var color: Color {
        switch entry.direction {
        case .tx: return Theme.accent
        case .rx: return Theme.ok
        case .event: return Theme.textSecondary
        case .error: return Theme.danger
        case .safety: return Theme.warning
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(PacketLog.timeOnlyFormatter.string(from: entry.date))
                Text(entry.direction.rawValue).bold().foregroundStyle(color)
                if !entry.shortCharacteristic.isEmpty { Text(entry.shortCharacteristic) }
            }
            .font(Theme.monoSmall)
            .foregroundStyle(Theme.textSecondary)
            if !entry.bytes.isEmpty {
                Text(Hex.string(entry.bytes)).font(Theme.monoSmall).foregroundStyle(color)
            }
            if !entry.note.isEmpty {
                Text(entry.note).font(.caption2).foregroundStyle(Theme.textPrimary.opacity(0.85))
            }
        }
        .textSelection(.enabled)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
