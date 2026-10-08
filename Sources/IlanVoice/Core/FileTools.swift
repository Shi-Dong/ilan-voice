import Foundation

/// Built-in file tools.
///
/// - `read_file` is always available.
/// - `edit_file` (replace an exact piece of text) and `write_file` (create or
///   replace a whole file) are turned on together by one switch in Settings,
///   and may touch any file except those on the block list there.
///
/// A few places that hold credentials are never read or written. Before any
/// change, the old file is copied to `~/Library/Application Support/Ilan
/// Voice/file-backups/` so it can be restored.
enum FileTools {
    static let readName = "read_file"
    static let editName = "edit_file"
    static let writeName = "write_file"

    static let maxReadBytes = 512 * 1024
    static let maxWriteBytes = 1024 * 1024
    static let defaultReadLines = 2000

    // MARK: Tool definitions

    static var readDefinition: [String: Any] {
        [
            "type": "function",
            "name": readName,
            "description": """
            Read a text file on the user's Mac. Returns its lines numbered from 1. \
            Use offset and limit for long files. Paths may start with ~; relative \
            paths are relative to the shell's working directory setting.
            """,
            "parameters": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "The file to read."],
                    "offset": ["type": "integer", "description": "First line to return (1-based). Optional."],
                    "limit": ["type": "integer", "description": "How many lines to return. Optional; default 2000."],
                ],
                "required": ["path"],
            ] as [String: Any],
        ]
    }

    static var editDefinition: [String: Any] {
        [
            "type": "function",
            "name": editName,
            "description": """
            Edit a text file by replacing an exact piece of text. old_text must \
            match the file exactly (including spaces and line breaks) and appear \
            exactly once, unless replace_all is true. Read the file first so the \
            text is exact. Files on the user's block list can't be edited.
            """,
            "parameters": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "The file to edit."],
                    "old_text": ["type": "string", "description": "The exact text to replace."],
                    "new_text": ["type": "string", "description": "The replacement text."],
                    "replace_all": ["type": "boolean", "description": "Replace every occurrence. Optional; default false."],
                ],
                "required": ["path", "old_text", "new_text"],
            ] as [String: Any],
        ]
    }

    static var writeDefinition: [String: Any] {
        [
            "type": "function",
            "name": writeName,
            "description": """
            Create a text file, or replace a whole file, with the given content. \
            Missing parent folders are created. Prefer edit_file for small changes \
            to an existing file. Files on the user's block list can't be written.
            """,
            "parameters": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "The file to write."],
                    "content": ["type": "string", "description": "The full new content of the file."],
                ],
                "required": ["path", "content"],
            ] as [String: Any],
        ]
    }

    // MARK: Paths

    /// Absolute path with ~ expanded, `.`/`..` removed and symlinks resolved.
    /// For a file that doesn't exist yet, the existing part of the path is resolved.
    static func resolve(_ path: String, relativeTo base: String) -> URL {
        var expanded = (path as NSString).expandingTildeInPath
        if !expanded.hasPrefix("/") {
            expanded = ((base as NSString).expandingTildeInPath as NSString).appendingPathComponent(expanded)
        }
        var url = URL(fileURLWithPath: expanded).standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
            missing.insert(url.lastPathComponent, at: 0)
            url.deleteLastPathComponent()
        }
        url = url.resolvingSymlinksInPath()
        for part in missing { url.appendPathComponent(part) }
        return url
    }

    /// Places that hold credentials: never read or written by these tools.
    static var protectedPaths: [String] {
        let home = NSHomeDirectory()
        return [home + "/.ssh", home + "/.gnupg", home + "/.aws", home + "/Library/Keychains",
                Paths.root.appendingPathComponent("secrets.json").path,
                Paths.root.appendingPathComponent("signing").path]
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
    }

    static func isInside(_ url: URL, _ folder: String) -> Bool {
        let path = url.path
        return path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    static func isProtected(_ url: URL) -> Bool {
        protectedPaths.contains { isInside(url, $0) }
    }

    /// The block list a fresh install starts with: macOS's own folders.
    static let defaultBlockList = "/System\n/Library\n/usr\n/bin\n/sbin\n/Applications"

    /// Blocked files and folders from Settings (one per line), resolved.
    static func blockedPaths(_ text: String) -> [String] {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { resolve($0, relativeTo: "/").path }
    }

    // MARK: Operations

    static func read(path: String, offset: Int?, limit: Int?, base: String) -> String {
        let url = resolve(path, relativeTo: base)
        if isProtected(url) { return "Error: \(url.path) holds credentials and can't be read." }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return "Error: no such file: \(url.path)"
        }
        if isDir.boolValue { return "Error: \(url.path) is a folder. Use run_shell with ls to list it." }
        guard let data = FileManager.default.contents(atPath: url.path) else { return "Error: can't read \(url.path)" }
        if data.count > 4 * 1024 * 1024 { return "Error: \(url.path) is too large (\(data.count) bytes)." }
        guard let text = String(data: data, encoding: .utf8) else { return "Error: \(url.path) is not a UTF-8 text file." }

        let lines = text.components(separatedBy: "\n")
        let start = max(1, offset ?? 1)
        let count = max(1, limit ?? defaultReadLines)
        guard start <= lines.count else { return "\(url.path) has \(lines.count) lines; offset \(start) is past the end." }
        let end = min(lines.count, start + count - 1)
        var out = ""
        for i in start...end {
            out += "\(String(format: "%6d", i))\t\(lines[i - 1])\n"
            if out.utf8.count > maxReadBytes { out += "…[truncated]\n"; break }
        }
        let more = end < lines.count ? " (lines \(start)–\(end) of \(lines.count); use offset to read more)" : ""
        return "\(url.path)\(more)\n" + out
    }

    static func edit(path: String, oldText: String, newText: String, replaceAll: Bool,
                     base: String, blocked: [String]) -> String {
        let url = resolve(path, relativeTo: base)
        if let refusal = writeRefusal(url, blocked: blocked) { return refusal }
        guard let data = FileManager.default.contents(atPath: url.path) else { return "Error: no such file: \(url.path)" }
        guard let text = String(data: data, encoding: .utf8) else { return "Error: \(url.path) is not a UTF-8 text file." }
        guard !oldText.isEmpty else { return "Error: old_text is empty." }
        let count = text.components(separatedBy: oldText).count - 1
        if count == 0 { return "Not changed: old_text was not found in \(url.path). Read the file and copy the text exactly." }
        if count > 1 && !replaceAll {
            return "Not changed: old_text appears \(count) times in \(url.path). Include more surrounding text, or set replace_all."
        }
        let updated = replaceAll
            ? text.replacingOccurrences(of: oldText, with: newText)
            : text.replacingCharacters(in: text.range(of: oldText)!, with: newText)
        if let error = save(updated, to: url, existing: true) { return error }
        let header = "Edited \(url.path): replaced \(replaceAll ? count : 1) occurrence\(replaceAll && count > 1 ? "s" : "")."
        return header + "\n" + diff(old: oldText, new: newText)
    }

    static func write(path: String, content: String, base: String, blocked: [String]) -> String {
        let url = resolve(path, relativeTo: base)
        if let refusal = writeRefusal(url, blocked: blocked) { return refusal }
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if exists && isDir.boolValue { return "Error: \(url.path) is a folder." }
        guard content.utf8.count <= maxWriteBytes else { return "Error: content is larger than \(maxWriteBytes) bytes." }
        if let error = save(content, to: url, existing: exists) { return error }
        let lines = content.isEmpty ? 0 : content.components(separatedBy: "\n").count
        return "\(exists ? "Replaced" : "Created") \(url.path) (\(lines) lines, \(content.utf8.count) bytes)."
    }

    private static func writeRefusal(_ url: URL, blocked: [String]) -> String? {
        if isProtected(url) { return "Not changed: \(url.path) holds credentials and can't be modified." }
        if let entry = blocked.first(where: { isInside(url, $0) }) {
            return "Not changed: \(url.path) is on the user's block list (\(entry)). The user can change the list in Settings → Shell → Files."
        }
        return nil
    }

    /// Backs up an existing file, then writes atomically.
    private static func save(_ text: String, to url: URL, existing: Bool) -> String? {
        do {
            if existing { try backup(url) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
            return nil
        } catch {
            return "Error: couldn't write \(url.path): \(error.localizedDescription)"
        }
    }

    static var backupRoot: URL { Paths.root.appendingPathComponent("file-backups", isDirectory: true) }

    private static func backup(_ url: URL) throws {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dest = backupRoot.appendingPathComponent(stamp).appendingPathComponent(String(url.path.dropFirst()))
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: dest)
    }

    /// A small before/after view for the transcript.
    static func diff(old: String, new: String, maxLines: Int = 40) -> String {
        let removed = old.components(separatedBy: "\n").prefix(maxLines).map { "- " + $0 }
        let added = new.components(separatedBy: "\n").prefix(maxLines).map { "+ " + $0 }
        return (removed + added).joined(separator: "\n")
    }
}
