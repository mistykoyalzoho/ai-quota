import Foundation

/// Reads string values from local SQLite databases (e.g. Cursor's state.vscdb).
enum LocalSQLiteReader {
    static func stringValue(dbPath: String, query: String) -> String? {
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [dbPath, query]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value, !value.isEmpty else { return nil }
            return value
        } catch {
            return nil
        }
    }
}
