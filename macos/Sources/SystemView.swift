import SwiftUI

/// Global tool data from the catalog: AI agents, editors, package managers, Xcode.
struct SystemView: View {
    @ObservedObject var model: Model
    @State private var pending: RemoveMode?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(Model.format(model.globalBytes)) in \(model.globalItems.count) tool locations")
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if model.scanningGlobal { ProgressView().controlSize(.small) }
            }
            if let n = model.globalNote { Text(n).font(.caption2).foregroundStyle(.tertiary) }
            if model.globalItems.isEmpty {
                Text(model.scanningGlobal ? "Measuring…" : "Nothing found.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) { ForEach(model.globalItems) { row($0) } }
                }
                .frame(height: 300)
            }
            Divider()
            if let m = model.message { Text(m).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Select safe") { model.selectSafeGlobal() }
                Button("Rescan") { Task { await model.scanGlobal() } }.disabled(model.scanningGlobal)
                    .contextMenu { Button("Full rescan") { Task { await model.scanGlobal(forceFull: true) } } }
                Spacer()
                Button("Move to Trash (\(model.globalSelection.count))") { pending = .trash }
                    .disabled(model.globalSelection.isEmpty || model.removing)
                Button("Delete now…", role: .destructive) { pending = .permanent }
                    .disabled(model.globalSelection.isEmpty || model.removing)
            }
        }
        .confirmationDialog(title, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            presenting: pending) { mode in
            Button(mode == .permanent ? "Delete permanently" : "Move to Trash",
                   role: mode == .permanent ? .destructive : nil) {
                Task { await model.removeGlobalSelected(mode) }
            }
        } message: { mode in
            Text(detail(mode))
        }
    }

    private var title: String {
        let n = model.globalSelection.count, size = Model.format(model.globalSelectedBytes)
        return pending == .permanent ? "Permanently delete \(n) locations (\(size))?" : "Move \(n) locations (\(size)) to the Trash?"
    }

    private func detail(_ mode: RemoveMode) -> String {
        var s = mode == .permanent ? "This cannot be undone. Nothing goes to the Trash." : "You can restore them from the Trash."
        let careful = model.globalSelectedItems.filter(\.isCareful).map { "\($0.tool) \($0.name)" }
        if !careful.isEmpty {
            s += " Includes data you may want to keep: " + careful.joined(separator: ", ")
                + ". Close the tools that use it first."
        }
        return s
    }

    private func row(_ item: GlobalItem) -> some View {
        HStack(alignment: .top) {
            Toggle("", isOn: Binding(
                get: { model.globalSelection.contains(item.path) },
                set: { on in
                    if on { model.globalSelection.insert(item.path) } else { model.globalSelection.remove(item.path) }
                }
            )).labelsHidden()
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("\(item.tool) · \(item.name)").fontWeight(.medium)
                    chip(item.category.replacingOccurrences(of: "_", with: " "), .secondary)
                    chip(item.isCareful ? "careful" : "safe", item.isCareful ? .orange : .green)
                }
                Text(item.description).font(.caption).foregroundStyle(.secondary)
                Text("If removed: \(item.loses)").font(.caption).foregroundStyle(item.isCareful ? .orange : .secondary)
            }
            Spacer()
            Text(Model.format(item.size)).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule()).foregroundStyle(color)
    }
}
