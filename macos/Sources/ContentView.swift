import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var model: Model
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            if model.items.isEmpty {
                Text(model.scanning ? "Scanning…" : "No caches found.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.items) { item in row(item) }
                    }
                }
                .frame(height: 300)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 520)
        .confirmationDialog(
            "Move \(model.selection.count) caches (\(Model.format(model.selectedBytes))) to the Trash?",
            isPresented: $confirming
        ) {
            Button("Move to Trash", role: .destructive) { Task { await model.trashSelected() } }
        } message: {
            Text("You can restore them from the Trash.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Dev Cache Clean").font(.headline)
                Spacer()
                if model.scanning { ProgressView().controlSize(.small) }
            }
            Text("\(Model.format(model.staleBytes)) reclaimable in \(model.staleItems.count) caches unused for \(model.staleDays)+ days")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Text(model.root).font(.caption).lineLimit(1).truncationMode(.head)
                Spacer()
                Button("Choose…") { chooseFolder() }.controlSize(.small)
                Stepper("\(model.staleDays)d", value: $model.staleDays, in: 1...365)
                    .controlSize(.small).fixedSize()
            }
        }
    }

    private func row(_ item: CacheItem) -> some View {
        let stale = item.idle_days >= model.staleDays
        return HStack {
            Toggle("", isOn: Binding(
                get: { model.selection.contains(item.path) },
                set: { on in
                    if on { model.selection.insert(item.path) } else { model.selection.remove(item.path) }
                }
            )).labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(shortPath(item.path)).lineLimit(1).truncationMode(.head)
                Text("\(item.label) · idle \(item.idle_days)d").font(.caption)
                    .foregroundStyle(stale ? .orange : .secondary)
            }
            Spacer()
            Text(Model.format(item.size)).monospacedDigit()
        }
        .padding(.vertical, 2)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let m = model.message { Text(m).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Select stale") { model.selectStale() }
                Button("Rescan") { Task { await model.scan() } }.disabled(model.scanning)
                Spacer()
                Button("Move to Trash (\(model.selection.count))", role: .destructive) { confirming = true }
                    .disabled(model.selection.isEmpty)
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
    }

    private func shortPath(_ p: String) -> String {
        p.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            model.root = url.path
            Task { await model.scan() }
        }
    }
}
