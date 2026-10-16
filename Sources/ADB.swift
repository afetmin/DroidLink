import Foundation
import Darwin

struct CommandResult {
    let status: Int32
    let output: String
    var ok: Bool { status == 0 }
}

struct Service: Identifiable, Hashable {
    let name: String
    let kind: String
    let endpoint: String
    var id: String { name + kind }
    var isPairing: Bool { kind == "_adb-tls-pairing._tcp" }
    var label: String { name.hasPrefix("adb-") ? String(name.dropFirst(4)) : name }
    func matches(_ serial: String) -> Bool {
        serial == endpoint || serial == name + "." + kind || serial == name + "." + kind + "."
    }
}

struct Device: Identifiable {
    let serial: String
    let state: String
    let model: String
    var id: String { serial }
    var wireless: Bool { serial.contains("_adb-tls-connect") || serial.contains(":") }
    var online: Bool { state == "device" }
}

struct Snapshot {
    var services: [Service] = []
    var devices: [Device] = []
    var problem: String? = nil
    var pairing: [Service] { services.filter(\.isPairing) }
    var connecting: [Service] { services.filter { !$0.isPairing } }
    var online: [Device] {
        var seen = Set<String>()
        return devices.filter { device in
            guard device.wireless && device.online else { return false }
            let identity = connecting.first { $0.matches(device.serial) }?.name ?? device.serial
            return seen.insert(identity).inserted
        }
    }
    func device(for service: Service) -> Device? {
        devices.first { $0.online && service.matches($0.serial) } ?? devices.first { service.matches($0.serial) }
    }
}

final class ADB: @unchecked Sendable {
    let path: String?
    init() {
        let fm = FileManager.default
        let candidates = [
            "/opt/homebrew/bin/adb", "/usr/local/bin/adb",
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk/platform-tools/adb").path
        ] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/adb" }
        path = candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    // No shell interpolation. Pairing codes travel through stdin and are never logged.
    func run(_ arguments: [String], input: String? = nil, timeout: TimeInterval = 6) -> CommandResult {
        guard let path else { return CommandResult(status: -1, output: "找不到 adb。请先安装 Android SDK Platform Tools。") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let inherited = ProcessInfo.processInfo.environment
        let allowed = ["HOME", "PATH", "TMPDIR", "USER", "LOGNAME", "LANG", "LC_ALL", "ANDROID_HOME", "ANDROID_SDK_ROOT"]
        var env = inherited.filter { allowed.contains($0.key) }
        env["ADB_MDNS"] = "1"
        process.environment = env
        let out = Pipe(), stdin = Pipe()
        process.standardOutput = out
        process.standardError = out
        process.standardInput = stdin
        do { try process.run() }
        catch { return CommandResult(status: -1, output: error.localizedDescription) }
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try? stdin.fileHandleForWriting.close()
        let fd = out.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        defer { try? out.fileHandleForReading.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        func drain() {
            for _ in 0..<32 {
                let count = Darwin.read(fd, &buffer, buffer.count)
                guard count > 0 else { break }
                if data.count < 65536 { data.append(contentsOf: buffer.prefix(min(count, 65536 - data.count))) }
            }
        }
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            drain()
            Thread.sleep(forTimeInterval: 0.04)
        }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.15)
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            // Bound the wait even if a descendant retains the output descriptor.
            let killDeadline = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning && ProcessInfo.processInfo.systemUptime < killDeadline { Thread.sleep(forTimeInterval: 0.02) }
        }
        drain()
        var value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if let input {
            let secret = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if !secret.isEmpty { value = value.replacingOccurrences(of: secret, with: "••••••") }
        }
        if timedOut { value = "操作超时。请确认手机在同一 Wi-Fi，并保持无线调试开启。\n" + value }
        return CommandResult(status: timedOut ? 124 : process.terminationStatus, output: value)
    }

    func snapshot(timeout: TimeInterval = 6) -> Snapshot {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let discovery = run(["mdns", "services"], timeout: max(0.1, min(3, timeout)))
        let connected = run(["devices", "-l"], timeout: max(0.1, deadline - ProcessInfo.processInfo.systemUptime))
        var snapshot = Snapshot()
        if !discovery.ok || !connected.ok {
            snapshot.problem = friendly(!connected.ok ? connected.output : discovery.output)
        }
        for line in discovery.output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 3 else { continue }
            let kind = fields[1].trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard ["_adb-tls-connect._tcp", "_adb-tls-pairing._tcp"].contains(kind), validEndpoint(fields[2]) else { continue }
            let suffix = "." + kind
            var name = fields[0].trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
            let service = Service(name: name, kind: kind, endpoint: fields[2])
            if !snapshot.services.contains(where: { $0.id == service.id }) { snapshot.services.append(service) }
        }
        for line in connected.output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, ["device", "offline", "unauthorized", "authorizing"].contains(fields[1]) else { continue }
            let model = fields.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") } ?? fields[0]
            snapshot.devices.append(Device(serial: fields[0], state: fields[1], model: model))
        }
        snapshot.services.sort { $0.id < $1.id }
        return snapshot
    }

    func restart() -> CommandResult {
        let stopped = run(["kill-server"], timeout: 3)
        guard stopped.ok else { return stopped }
        return run(["start-server"], timeout: 3)
    }

    func pair(endpoint: String, code: String) -> CommandResult {
        guard validEndpoint(endpoint), code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return CommandResult(status: -1, output: "请选择手机，并输入六位数字配对码。")
        }
        var result = run(["pair", endpoint], input: code + "\n", timeout: 12)
        if !result.ok && result.output.lowercased().contains("protocol fault") {
            let repair = restart()
            guard repair.ok else { return repair }
            result = run(["pair", endpoint], input: code + "\n", timeout: 10)
        }
        return result
    }

    func connect(endpoint: String, timeout: TimeInterval = 7) -> CommandResult {
        guard validEndpoint(endpoint) else { return CommandResult(status: -1, output: "地址格式应为 IP:端口，例如 192.0.2.10:37123。") }
        let result = run(["connect", endpoint], timeout: timeout)
        // adb connect may return exit 0 even when the transport failed.
        let lower = result.output.lowercased()
        let success = result.ok && (lower.contains("connected to ") || lower.contains("already connected to "))
        return CommandResult(status: success ? 0 : (result.status == 0 ? -1 : result.status), output: result.output)
    }

    func host(of endpoint: String) -> String {
        guard let separator = endpoint.lastIndex(of: ":") else { return endpoint }
        return String(endpoint[..<separator])
    }

    func hardwareSerial(for transport: String) -> String? {
        let result = run(["-s", transport, "shell", "getprop", "ro.serialno"], timeout: 2)
        let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.ok, !value.isEmpty, value != "unknown", value.count <= 128,
              value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-.")).contains($0) }) else { return nil }
        return value
    }

    func validEndpoint(_ value: String) -> Bool {
        // LAN addresses / DNS names only; reject spaces, flags and shell-like input.
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]"), value.index(after: close) < value.endIndex,
                  value[value.index(after: close)] == ":",
                  let port = Int(value[value.index(close, offsetBy: 2)...]), (1...65535).contains(port) else { return false }
            let host = String(value[value.index(after: value.startIndex)..<close])
            let address = host.split(separator: "%", omittingEmptySubsequences: false)
            guard address.count <= 2 else { return false }
            var parsed = in6_addr()
            guard inet_pton(AF_INET6, String(address[0]), &parsed) == 1 else { return false }
            if address.count == 2 {
                let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
                guard !address[1].isEmpty, address[1].unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
            }
            return true
        }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let port = Int(parts[1]), (1...65535).contains(port), !parts[0].isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        return !parts[0].hasPrefix("-") && parts[0].unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    func friendly(_ output: String) -> String {
        let lower = output.lowercased()
        if lower.contains("protocol fault") { return "ADB 服务通信异常。点击「修复 ADB」后重试。" }
        if lower.contains("pairing code") || lower.contains("wrong password") || lower.contains("authentication") || lower.contains("failed to pair") {
            return "配对未完成。请重新打开手机的配对码窗口，使用当前显示的六位配对码。"
        }
        if lower.contains("timed out") || lower.contains("refused") || lower.contains("cannot connect") || lower.contains("failed to connect") {
            return "手机暂时无法连接。请确认同一 Wi-Fi、无线调试已开启，并重新检测。首次使用请先配对。"
        }
        return output.isEmpty ? "操作未完成，请重新检测或修复 ADB。" : String(output.prefix(500))
    }
}
