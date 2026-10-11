import Foundation
import Darwin

/// Одна поднятая локалка: процесс разработчика, который слушает порт.
struct LocalServer: Identifiable, Equatable {
    let pid: Int32
    let ppid: Int32
    let ports: [Int]
    let project: String
    let cwd: String
    let kind: String
    let uptime: TimeInterval
    let memoryMB: Double
    let cpu: Double
    /// Подпись агента через `localki name`; пусто — подписи нет.
    var name: String = ""
    var purpose: String = ""

    var id: Int32 { pid }
    var title: String { name.isEmpty ? project : name }
    var url: URL? { ports.first.flatMap { URL(string: "http://127.0.0.1:\($0)") } }
}

/// Тяжёлый фон, который не является локалкой, но грузит машину.
struct HeavyGroup: Identifiable, Equatable {
    enum Action: Equatable { case none, stopDocker }
    let id: String
    let title: String
    let count: Int
    let memoryMB: Double
    let cpu: Double
    let running: Bool
    let action: Action
}

struct Snapshot: Equatable {
    var servers: [LocalServer] = []
    var heavy: [HeavyGroup] = []
}

private struct ProcInfo {
    let pid: Int32, ppid: Int32, uid: Int, rssKB: Double, cpu: Double, etime: TimeInterval, command: String
}

enum Shell {
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

enum Scanner {
    static let home = NSHomeDirectory()

    static func scan() -> Snapshot {
        let procs = processTable()
        let listeners = listeningPorts()
        let myUID = Int(getuid())
        let devPIDs = listeners.keys.filter { pid in
            guard let p = procs[pid], p.uid == myUID else { return false }
            return isDevServer(executable: executablePath(pid), command: p.command)
        }
        let cwds = workingDirs(Array(devPIDs))
        let labels = readLabels()
        let now = Date().timeIntervalSince1970
        let servers = devPIDs.compactMap { pid -> LocalServer? in
            guard let p = procs[pid] else { return nil }
            let cwd = cwds[pid] ?? ""
            let ports = listeners[pid]!.sorted()
            var s = LocalServer(pid: pid, ppid: p.ppid, ports: ports,
                                project: projectName(cwd: cwd, command: p.command), cwd: cwd,
                                kind: kind(of: p.command), uptime: p.etime,
                                memoryMB: p.rssKB / 1024, cpu: p.cpu)
            // Подпись действует, только если сделана после запуска этого процесса:
            // иначе она осталась от прежнего сервера на том же порту.
            let started = now - p.etime - 60
            if let label = ports.compactMap({ labels[$0] }).first(where: { $0.created >= started }) {
                s.name = label.name
                s.purpose = label.purpose
            }
            return s
        }.sorted { $0.uptime > $1.uptime }
        return Snapshot(servers: servers, heavy: heavyGroups(procs.values))
    }

    // MARK: таблица процессов

    private static func processTable() -> [Int32: ProcInfo] {
        let out = Shell.run("/bin/ps", ["-axo", "pid=,ppid=,uid=,rss=,%cpu=,etime=,command="])
        var table: [Int32: ProcInfo] = [:]
        for line in out.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true)
            guard f.count == 7, let pid = Int32(f[0]), let ppid = Int32(f[1]) else { continue }
            table[pid] = ProcInfo(pid: pid, ppid: ppid, uid: Int(f[2]) ?? -1,
                                  rssKB: Double(f[3]) ?? 0, cpu: Double(f[4].replacingOccurrences(of: ",", with: ".")) ?? 0,
                                  etime: parseEtime(String(f[5])), command: String(f[6]))
        }
        return table
    }

    /// ps etime: [[dd-]hh:]mm:ss
    static func parseEtime(_ s: String) -> TimeInterval {
        var days = 0.0, rest = s
        if let dash = s.firstIndex(of: "-") {
            days = Double(s[..<dash]) ?? 0
            rest = String(s[s.index(after: dash)...])
        }
        let parts = rest.split(separator: ":").compactMap { Double($0) }
        var sec = 0.0
        for v in parts { sec = sec * 60 + v }
        return days * 86400 + sec
    }

    private static func listeningPorts() -> [Int32: Set<Int>] {
        let out = Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"])
        var result: [Int32: Set<Int>] = [:]
        var current: Int32 = 0
        for line in out.split(separator: "\n") {
            if line.hasPrefix("p") { current = Int32(line.dropFirst()) ?? 0 }
            else if line.hasPrefix("n"), let colon = line.lastIndex(of: ":"), let port = Int(line[line.index(after: colon)...]) {
                result[current, default: []].insert(port)
            }
        }
        return result
    }

    private static func workingDirs(_ pids: [Int32]) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let out = Shell.run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fpn", "-p", pids.map(String.init).joined(separator: ",")])
        var result: [Int32: String] = [:]
        var current: Int32 = 0
        for line in out.split(separator: "\n") {
            if line.hasPrefix("p") { current = Int32(line.dropFirst()) ?? 0 }
            else if line.hasPrefix("n") { result[current] = String(line.dropFirst()) }
        }
        return result
    }

    // MARK: подписи `localki name`

    private struct Label: Decodable { let name: String; let purpose: String; let created: Double }

    static let labelsDir = URL(fileURLWithPath: home).appendingPathComponent(".localki/names")

    private static func readLabels() -> [Int: Label] {
        let files = (try? FileManager.default.contentsOfDirectory(at: labelsDir, includingPropertiesForKeys: nil)) ?? []
        var result: [Int: Label] = [:]
        for url in files where url.pathExtension == "json" {
            guard let port = Int(url.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: url),
                  let label = try? JSONDecoder().decode(Label.self, from: data) else { continue }
            result[port] = label
        }
        return result
    }

    static func removeLabels(ports: [Int]) {
        for p in ports { try? FileManager.default.removeItem(at: labelsDir.appendingPathComponent("\(p).json")) }
    }

    // MARK: классификация

    private static let devRuntimes = ["python", "Python", "node", "bun", "deno", "ruby", "php", "uvicorn", "gunicorn", "java"]

    /// Настоящий путь к исполняемому файлу: node-инструменты подменяют имя процесса
    /// (`http-server`, `next-server`), а по пути видно, что это node.
    static func executablePath(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : ""
    }

    static func isDevServer(executable: String, command: String) -> Bool {
        let path = executable.isEmpty ? (command.split(separator: " ").first.map(String.init) ?? "") : executable
        if path.contains("/Contents/Resources/binaries/") || path.contains("node_modules/") || command.contains("node_modules/") { return true }
        let name = (path as NSString).lastPathComponent
        return devRuntimes.contains { name.hasPrefix($0) }
    }

    static func kind(of command: String) -> String {
        let c = command.lowercased()
        let table: [(String, String)] = [("storybook", "Storybook"), ("vite", "Vite"), ("next", "Next.js"),
                                         ("astro", "Astro"), ("remotion", "Remotion"), ("http.server", "статика"), ("http-server", "статика"),
                                         ("uvicorn", "API"), ("gunicorn", "API"), ("serve.py", "сервер"),
                                         ("server.py", "сервер"), ("webpack", "Webpack")]
        for (needle, label) in table where c.contains(needle) { return label }
        if c.contains("python") { return "Python" }
        if c.contains("node") { return "Node" }
        return "процесс"
    }

    /// Папки, относительно которых показывается имя проекта: по строке на путь в
    /// `~/.localki/roots` (можно с `~`), домашняя папка всегда последней.
    static let projectRoots: [String] = {
        let file = URL(fileURLWithPath: home).appendingPathComponent(".localki/roots")
        let lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n")
        var roots = lines.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { ($0 as NSString).expandingTildeInPath }
            .map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        roots.append(home + "/")
        return roots
    }()

    static func projectName(cwd: String, command: String) -> String {
        var path = cwd
        // http.server --directory X: смотрим на то, что реально раздаётся
        if let r = command.range(of: "--directory ") {
            path = String(command[r.upperBound...].split(separator: " ").first ?? "")
        }
        if path.isEmpty || path == "/" { return "без папки" }
        for marker in ["/.dave-work", "/node_modules", "/.venv"] {
            if let r = path.range(of: marker) { path = String(path[..<r.lowerBound]) }
        }
        for root in projectRoots where path.hasPrefix(root) {
            path = String(path.dropFirst(root.count))
            break
        }
        let parts = path.split(separator: "/").map(String.init)
        return parts.suffix(3).joined(separator: " / ")
    }

    // MARK: тяжёлый фон

    private static func heavyGroups<S: Sequence>(_ procs: S) -> [HeavyGroup] where S.Element == ProcInfo {
        func sum(_ match: (String) -> Bool) -> (Int, Double, Double) {
            var n = 0, mem = 0.0, cpu = 0.0
            for p in procs where match(p.command) { n += 1; mem += p.rssKB / 1024; cpu += p.cpu }
            return (n, mem, cpu)
        }
        let docker = sum { $0.contains("com.apple.Virtualization.VirtualMachine") || $0.contains("limactl") || $0.contains("/.colima/") }
        let claude = sum { $0.contains("/.local/bin/claude") || $0.hasSuffix("/claude") || $0.contains("claude.app/Contents/MacOS/claude") }
        let codex = sum { $0.contains("/codex") && !$0.contains("Codex Computer Use") }
        let mcp = sum { $0.contains("mcp") && ($0.contains("node") || $0.contains("npm exec") || $0.contains("npx")) }
        let browser = sum { $0.contains("D.A.V.E.'s Chrome") }
        let obs = sum { $0.contains("/OBS.app/") }
        return [
            HeavyGroup(id: "docker", title: "Docker (Colima)", count: docker.0, memoryMB: docker.1, cpu: docker.2,
                       running: docker.0 > 0, action: .stopDocker),
            HeavyGroup(id: "claude", title: "Claude", count: claude.0, memoryMB: claude.1, cpu: claude.2, running: claude.0 > 0, action: .none),
            HeavyGroup(id: "codex", title: "Codex", count: codex.0, memoryMB: codex.1, cpu: codex.2, running: codex.0 > 0, action: .none),
            HeavyGroup(id: "mcp", title: "MCP-серверы агентов", count: mcp.0, memoryMB: mcp.1, cpu: mcp.2, running: mcp.0 > 0, action: .none),
            HeavyGroup(id: "browser", title: "Браузер D.A.V.E.", count: browser.0, memoryMB: browser.1, cpu: browser.2, running: browser.0 > 0, action: .none),
            HeavyGroup(id: "obs", title: "OBS", count: obs.0, memoryMB: obs.1, cpu: obs.2, running: obs.0 > 0, action: .none),
        ].filter { $0.running }
    }

    // MARK: действия

    /// Останавливает сервер: SIGTERM, через 2 с SIGKILL. Сироту-обёртку `npm exec` гасит вместе с ним.
    static func stop(_ s: LocalServer) {
        let parent = Shell.run("/bin/ps", ["-o", "ppid=,command=", "-p", String(s.ppid)]).trimmingCharacters(in: .whitespacesAndNewlines)
        let parentIsWrapper = parent.contains("npm exec") || parent.contains("npx ")
        kill(s.pid, SIGTERM)
        if parentIsWrapper { kill(s.ppid, SIGTERM) }
        removeLabels(ports: s.ports)
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if kill(s.pid, 0) == 0 { kill(s.pid, SIGKILL) }
        }
    }

    static func stopDocker() {
        for path in ["/opt/homebrew/bin/colima", "/usr/local/bin/colima"] where FileManager.default.isExecutableFile(atPath: path) {
            Shell.run(path, ["stop"])
            return
        }
    }
}
