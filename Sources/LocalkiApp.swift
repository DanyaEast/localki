import SwiftUI
import AppKit

@main
struct LocalkiApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "server.rack")
                if model.snapshot.servers.count > 0 { Text("\(model.snapshot.servers.count)") }
            }
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class Model: ObservableObject {
    @Published var snapshot = Snapshot()
    @Published var busy = false
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        Task.detached(priority: .utility) {
            let snap = Scanner.scan()
            await MainActor.run { if self.snapshot != snap { self.snapshot = snap } }
        }
    }

    func stop(_ servers: [LocalServer]) {
        busy = true
        Task.detached {
            servers.forEach(Scanner.stop)
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run { self.busy = false; self.refresh() }
        }
    }

    func stopDocker() {
        busy = true
        Task.detached {
            Scanner.stopDocker()
            await MainActor.run { self.busy = false; self.refresh() }
        }
    }
}

// MARK: - Форматирование

enum Fmt {
    static func age(_ t: TimeInterval) -> String {
        if t >= 86400 { return "\(Int(t / 86400)) д" }
        if t >= 3600 { return "\(Int(t / 3600)) ч" }
        return "\(max(1, Int(t / 60))) мин"
    }
    static func memory(_ mb: Double) -> String {
        mb >= 1024 ? String(format: "%.1f ГБ", mb / 1024) : "\(Int(mb.rounded())) МБ"
    }
}

// MARK: - Панель

struct PanelView: View {
    @ObservedObject var model: Model
    private let day: TimeInterval = 86400

    var body: some View {
        let servers = model.snapshot.servers
        let stale = servers.filter { $0.uptime >= day }

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Локалки").font(.system(size: 13, weight: .semibold))
                Text("\(servers.count)").font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                IconButton(symbol: "arrow.clockwise", help: "Обновить") { model.refresh() }
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)

            if servers.isEmpty {
                Text("Ничего не поднято")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 18)
            } else {
                // В панели MenuBarExtra ScrollView без явной высоты схлопывается в ноль,
                // поэтому высота задаётся числом: до семи строк без прокрутки.
                let rows = VStack(spacing: 0) {
                    ForEach(servers) { s in
                        ServerRow(server: s) { model.stop([s]) }
                    }
                }
                if servers.count <= 7 {
                    rows
                } else {
                    ScrollView { rows }.frame(height: 7 * ServerRow.height)
                }

                HStack(spacing: 8) {
                    Button("Погасить старше суток") { model.stop(stale) }
                        .disabled(stale.isEmpty || model.busy)
                    Button("Погасить все") { model.stop(servers) }
                        .disabled(model.busy)
                    Spacer()
                }
                .controlSize(.small)
                .padding(.horizontal, 14).padding(.vertical, 10)
            }

            if !model.snapshot.heavy.isEmpty {
                Divider()
                Text("Что ещё грузит мак")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
                ForEach(model.snapshot.heavy) { g in
                    HeavyRow(group: g, busy: model.busy) { model.stopDocker() }
                }
                .padding(.bottom, 6)
            }

            Divider()
            HStack {
                Spacer()
                Button("Выйти") { NSApp.terminate(nil) }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .frame(width: 400)
        .onAppear { model.refresh() }
    }
}

struct ServerRow: View {
    static let height: CGFloat = 46
    let server: LocalServer
    let onStop: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(server.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1).truncationMode(server.name.isEmpty ? .head : .tail)
                if !server.purpose.isEmpty {
                    Text(server.purpose)
                        .font(.system(size: 12))
                        .lineLimit(1).truncationMode(.tail)
                }
                Text(details)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            HStack(spacing: 2) {
                IconButton(symbol: "globe", help: "Открыть в браузере") {
                    if let url = server.url { NSWorkspace.shared.open(url) }
                }
                IconButton(symbol: "folder", help: "Показать папку") {
                    guard !server.cwd.isEmpty else { return }
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: server.cwd)
                }
                IconButton(symbol: "stop.circle", help: "Остановить", role: .destructive, action: onStop)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: server.purpose.isEmpty ? Self.height : Self.height + 16)
        .background(hover ? Color.primary.opacity(0.06) : .clear)
        .onHover { hover = $0 }
        .help([server.purpose, server.cwd].filter { !$0.isEmpty }.joined(separator: "\n"))
    }

    private var details: String {
        let ports = server.ports.map { ":\($0)" }.joined(separator: " ")
        var parts = [ports, server.kind, Fmt.age(server.uptime), Fmt.memory(server.memoryMB)]
        // Подписанной локалке папка уходит в мету: имя её уже не показывает.
        if !server.name.isEmpty { parts.insert(server.project, at: 0) }
        return parts.joined(separator: " · ")
    }
}

struct HeavyRow: View {
    let group: HeavyGroup
    let busy: Bool
    let onStopDocker: () -> Void

    var body: some View {
        HStack {
            Text(group.title).font(.system(size: 12))
            Spacer()
            Text(summary).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            if group.action == .stopDocker {
                IconButton(symbol: "stop.circle", help: "Остановить Docker", role: .destructive, action: onStopDocker)
                    .disabled(busy)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 4)
    }

    private var summary: String {
        var parts = ["\(group.count) проц.", Fmt.memory(group.memoryMB)]
        if group.cpu >= 1 { parts.append("CPU \(Int(group.cpu.rounded()))%") }
        return parts.joined(separator: " · ")
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var role: ButtonRole? = nil
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 26, height: 24)
                .foregroundStyle(role == .destructive && hover ? Color.red : Color.secondary)
                .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.primary.opacity(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
