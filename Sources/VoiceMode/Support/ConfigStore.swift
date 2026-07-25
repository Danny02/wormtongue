import Foundation
import VoiceModeCore

enum ConfigStore {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/voicemode/config.json")
    }

    /// Loads the config, seeding the file from the built-in example on first run.
    /// A broken config degrades to defaults with a message rather than failing to launch.
    static func load() -> (config: Config, error: String?) {
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try seed()
            } catch {
                return (.fallback, "Could not write \(url.path): \(error.localizedDescription)")
            }
        }
        do {
            return (try Config.decode(try Data(contentsOf: url)), nil)
        } catch {
            return (
                .fallback,
                "\(url.lastPathComponent) is invalid, using defaults: \(error.localizedDescription)"
            )
        }
    }

    private static func seed() throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Config.seed.encoded().write(to: url)
    }
}
