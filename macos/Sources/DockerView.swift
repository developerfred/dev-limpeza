import SwiftUI

struct DockerView: View {
    @ObservedObject var docker: DockerModel
    @State private var pending: DockerRow?

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
        .confirmationDialog(
            pending.map { "Clean \($0.title.lowercased()) (\($0.reclaimableText))?" } ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { row in
            Button("Clean \(row.title.lowercased())", role: .destructive) {
                Task { await docker.prune(row) }
            }
        } message: { row in
            Text(row.warning)
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
            Button("Clean") { pending = row }
                .disabled(row.reclaimableBytes == 0 || docker.busy)
        }
        .padding(.vertical, 2)
    }
}
