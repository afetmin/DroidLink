import Foundation
import SwiftUI
import Combine
import Darwin

@MainActor
final class DeviceNames: ObservableObject {
    @Published private(set) var saveError: String?

    private struct Storage: Codable {
        var version: Int
        var names: [String: String]
        var aliases: [String: String]

        init(version: Int = 1, names: [String: String] = [:], aliases: [String: String] = [:]) {
            self.version = version
            self.names = names
            self.aliases = aliases
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            names = try container.decodeIfPresent([String: String].self, forKey: .names) ?? [:]
            aliases = try container.decodeIfPresent([String: String].self, forKey: .aliases) ?? [:]
        }
    }

    private enum StorageError: LocalizedError {
        case unsupportedVersion
        case malformed
        case blocked

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion, .malformed:
                return "设备名称文件格式无法读取。"
            case .blocked:
                return "设备名称文件无法读取，原文件已保留。"
            }
        }
    }

    private let fileManager = FileManager.default
    private let directory: URL
    private let fileURL: URL
    @Published private var storage = Storage()
    private var persistenceBlocked = false

    init(directory: URL? = nil) {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
        self.directory = directory ?? applicationSupport.appendingPathComponent("AndroidWireless", isDirectory: true)
        self.fileURL = self.directory.appendingPathComponent("device-names.json", isDirectory: false)
        load()
    }

    func key(for service: Service) -> String {
        resolveAlias(serviceKey(for: service))
    }

    func key(for device: Device) -> String {
        let serial = device.serial
        if let serviceName = mdnsServiceName(from: serial) {
            return resolveAlias(serviceKey(for: serviceName))
        }
        if serial.contains(":") {
            return resolveAlias("transport:" + serial)
        }
        return resolveAlias("serial:" + serial)
    }

    func name(for key: String) -> String? {
        guard !key.isEmpty else { return nil }
        let resolved = resolveAlias(key)
        return normalizedName(storage.names[resolved])
    }

    @discardableResult
    func setName(_ value: String, for key: String) -> Bool {
        guard !key.isEmpty else {
            saveError = "设备名称保存失败：设备标识为空。"
            return false
        }

        var next = storage
        let resolved = resolveAlias(key)
        let trimmed = normalizedName(value) ?? ""
        if trimmed.isEmpty {
            next.names.removeValue(forKey: resolved)
        } else {
            next.names[resolved] = trimmed
        }
        return commit(next)
    }

    @discardableResult
    func learn(serial: String, service: Service?, transport: String) -> Bool {
        let serial = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serial.isEmpty else {
            saveError = "设备名称保存失败：硬件序列号为空。"
            return false
        }

        let canonicalKey = "serial:" + serial
        var fallbackKeys: [String] = []
        if let service {
            let fallback = serviceKey(for: service)
            if !fallback.isEmpty { fallbackKeys.append(fallback) }
        }
        let transport = transport.trimmingCharacters(in: .whitespacesAndNewlines)
        if !transport.isEmpty {
            fallbackKeys.append("transport:" + transport)
        }
        var uniqueFallbackKeys: [String] = []
        for fallback in fallbackKeys where !uniqueFallbackKeys.contains(fallback) {
            uniqueFallbackKeys.append(fallback)
        }
        fallbackKeys = uniqueFallbackKeys

        var next = storage
        let existingCanonical = normalizedName(storage.names[canonicalKey])
        var migrated = existingCanonical
        if migrated == nil {
            for fallback in fallbackKeys {
                if let value = name(for: fallback) {
                    migrated = normalizedName(value)
                    if migrated != nil { break }
                }
            }
        }
        if let migrated {
            next.names[canonicalKey] = migrated
        } else {
            next.names.removeValue(forKey: canonicalKey)
        }

        for fallback in fallbackKeys {
            next.aliases[fallback] = canonicalKey
            next.names.removeValue(forKey: fallback)
        }
        return commit(next)
    }

    private func load() {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(Storage.self, from: data)
            guard decoded.version == 1 else { throw StorageError.unsupportedVersion }
            storage = decoded
        } catch {
            persistenceBlocked = true
            saveError = StorageError.malformed.localizedDescription
        }
    }

    private func commit(_ next: Storage) -> Bool {
        guard !persistenceBlocked else {
            saveError = StorageError.blocked.localizedDescription
            return false
        }
        do {
            try write(next)
            storage = next
            saveError = nil
            return true
        } catch {
            saveError = "设备名称保存失败：\(error.localizedDescription)"
            return false
        }
    }

    private func write(_ value: Storage) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)

        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
        }

        let temporaryURL = directory.appendingPathComponent(
            ".device-names-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        do {
            try data.write(to: temporaryURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: temporaryURL.path
            )
            let renameResult = temporaryURL.path.withCString { sourcePath in
                fileURL.path.withCString { destinationPath in
                    Darwin.rename(sourcePath, destinationPath)
                }
            }
            guard renameResult == 0 else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))]
                )
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func serviceKey(for service: Service) -> String {
        serviceKey(for: service.name)
    }

    private func serviceKey(for name: String) -> String {
        let normalized = normalizedServiceName(name)
        return normalized.isEmpty ? "" : "service:" + normalized
    }

    private func normalizedServiceName(_ name: String) -> String {
        var value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix(".") { value.removeLast() }
        if value.hasPrefix("adb-") { value.removeFirst(4) }
        guard let dash = value.lastIndex(of: "-"),
              dash > value.startIndex,
              value.index(after: dash) < value.endIndex else {
            return value
        }
        return String(value[..<dash])
    }

    private func mdnsServiceName(from serial: String) -> String? {
        var value = serial
        while value.hasSuffix(".") { value.removeLast() }
        let suffix = "._adb-tls-connect._tcp"
        guard value.hasSuffix(suffix) else { return nil }
        let name = String(value.dropLast(suffix.count))
        return name.isEmpty ? nil : name
    }

    private func resolveAlias(_ key: String) -> String {
        guard !key.isEmpty else { return key }
        var current = key
        var visited = Set<String>()
        while visited.insert(current).inserted,
              let next = storage.aliases[current],
              !next.isEmpty {
            current = next
        }
        return current
    }

    private func normalizedName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(80))
    }
}
