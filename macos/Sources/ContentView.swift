import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var model: Model
    @ObservedObject var docker: DockerModel
    @State private var pending: RemoveMode?
    @State private var tab: Int

    init(model: Model, docker: DockerModel, initialTab: Int = 0) {
        _model = ObservedObject(wrappedValue: model)
        _docker = ObservedObject(wrappedValue: docker)
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Picker("", selection: $tab) {
                Text("Dev caches").tag(0)
                Text("System").tag(1)
                Text("Docker").tag(2)
            }
            .pickerStyle(.segmented).labelsHidden()
            Divider()
            if tab == 2 {
                DockerView(docker: docker).frame(minHeight: 200, alignment: .top)
            } else if tab == 1 {
                SystemView(model: model)
            } else if model.items.isEmpty {
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
            if tab == 0 {
                Divider()
                footer
            }
        }
        .padding(14)
        .frame(width: 520)
        .confirmationDialog(
            pending == .permanent
                ? "Permanently delete \(model.selection.count) caches (\(Model.format(model.selectedBytes)))?"
                : "Move \(model.selection.count) caches (\(Model.format(model.selectedBytes))) to the Trash?",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { mode in
            Button(mode == .permanent ? "Delete permanently" : "Move to Trash",
                   role: mode == .permanent ? .destructive : nil) {
                Task { await model.removeSelected(mode) }
            }
        } message: { mode in
            Text(mode == .permanent
                 ? "This cannot be undone. Nothing goes to the Trash."
                 : "You can restore them from the Trash. Space is freed when you empty the Trash.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Dev Cache Clean").font(.headline)
                Spacer()
                if model.scanning { ProgressView().controlSize(.small) }
            }
            if tab == 0 {
                Text("\(Model.format(model.staleBytes)) reclaimable in \(model.staleItems.count) caches unused for \(model.staleDays)+ days")
                    .font(.subheadline).foregroundStyle(.secondary)
                if let n = model.scanNote { Text(n).font(.caption2).foregroundStyle(.tertiary) }
                HStack {
                    Text(model.root).font(.caption).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button("Choose…") { chooseFolder() }.controlSize(.small)
                    Stepper("\(model.staleDays)d", value: $model.staleDays, in: 1...365)
                        .controlSize(.small).fixedSize()
                }
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
                    .contextMenu { Button("Full rescan") { Task { await model.scan(forceFull: true) } } }
                Spacer()
                Button("Move to Trash (\(model.selection.count))") { pending = .trash }
                    .disabled(model.selection.isEmpty || model.removing)
                Button("Delete now…", role: .destructive) { pending = .permanent }
                    .disabled(model.selection.isEmpty || model.removing)
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
