import Foundation

public protocol SettingsStoring {
    func load() throws -> AppSettings
    func save(_ settings: AppSettings) throws
}

public struct SettingsStore: SettingsStoring, Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static func applicationStore() -> SettingsStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SettingsStore(url: base.appendingPathComponent("RegionBlur/settings.json"))
    }

    public func load() throws -> AppSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return AppSettings() }
        do {
            return try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: url))
        } catch {
            let backup = url.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try FileManager.default.moveItem(at: url, to: backup)
            return AppSettings()
        }
    }

    public func save(_ settings: AppSettings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(settings)
        try data.write(to: url, options: .atomic)
    }
}
