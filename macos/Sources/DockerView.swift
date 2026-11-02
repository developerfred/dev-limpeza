import SwiftUI

struct DockerView: View {
    @ObservedObject var docker: DockerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch docker.state {
            case .idle, .loading:
                ProgressView("Asking Docker…").frame(maxWidth: .infinity, minHeight: 120)
            case .unavailable(let why):
                VStack(spacing: 8) {
                    Image(systemName: "shippingbox").font(.largeTitle).foregroundStyle(.secondary)
                    Text(why).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Retry") { Task { await docker.refresh() } }
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            case .ready(let rows):
                Text("\(Model.format(docker.reclaimableBytes)) reclaimable in Docker")
                    .font(.subheadline).foregroundStyle(.secondary)
                ForEach(rows) { row in line(row) }
                Text("Docker cleanups are permanent and do not go to the Trash.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let m = docker.message { Text(m).font(.caption).foregroundStyle(.secondary) }
        }
        .task { if docker.state == .idle { await docker.refresh() } }
    }

    private func confirmClean(_ row: DockerRow) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Clean \(row.title.lowercased()) (\(row.reclaimableText))?"
        alert.informativeText = row.warning
        alert.addButton(withTitle: "Clean \(row.title.lowercased())")
        alert.addButton(withTitle: "Cancel")
        if let first = alert.buttons.first { first.hasDestructiveAction = true }
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            Task { await docker.prune(row) }
        }
    }

    private func line(_ row: DockerRow) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                Text("\(row.total) total · \(row.active) in use · \(row.size)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(row.reclaimableText).monospacedDigit()
            Button("Clean") { confirmClean(row) }
                .disabled(row.reclaimableBytes == 0 || docker.busy)
        }
        .padding(.vertical, 2)
    }
}
