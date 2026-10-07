import Foundation
import Security

/// All of Ilan Voice's API keys and other secrets, by name.
///
/// They live in one file, `~/Library/Application Support/Ilan Voice/
/// secrets.json`, readable only by you (mode 0600), the same way `mcp.json`
/// already holds MCP tokens. Names are environment-variable style
/// (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, …): a secret not in the file falls
/// back to the environment variable of the same name, and `mcp.json` can
/// refer to any of them as `${NAME}` instead of pasting the value in.
///
/// Why not the Keychain: Keychain items remember which build of an app
/// created them. Ilan Voice is rebuilt on your Mac at every update without an
/// Apple developer certificate, so macOS treated each update as a stranger
/// and asked for your password before handing the key back.
enum SecretStore {
    static let openAI = "OPENAI_API_KEY"
    static let gemini = "GEMINI_API_KEY"

    private static var file: URL { Paths.root.appendingPathComponent("secrets.json") }

    /// The stored value, else the environment variable of the same name.
    static func get(_ name: String) -> String? {
        if let value = all()[name], !value.isEmpty { return value }
        if let value = ProcessInfo.processInfo.environment[name], !value.isEmpty { return value }
        return nil
    }

    /// Stores a secret; an empty value removes it.
    static func set(_ name: String, _ value: String) {
        var secrets = all()
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { secrets.removeValue(forKey: name) } else { secrets[name] = value }
        write(secrets)
    }

    static func remove(_ name: String) { set(name, "") }

    static func all() -> [String: String] {
        migrateIfNeeded()
        guard let data = try? Data(contentsOf: file),
              let secrets = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return secrets
    }

    /// Replaces every `${NAME}` in `text` with that secret (left as is when
    /// the secret is unknown).
    static func expand(_ text: String) -> String {
        guard text.contains("${") else { return text }
        var out = text
        let pattern = try! NSRegularExpression(pattern: #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}"#)
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: out), let nameRange = Range(match.range(at: 1), in: text),
                  let value = get(String(text[nameRange])) else { continue }
            out.replaceSubrange(whole, with: value)
        }
        return out
    }

    private static func write(_ secrets: [String: String]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(secrets) else { return }
        FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    // MARK: One-time move out of the Keychain

    private static var migrated = false

    /// Keys the app used to keep in the Keychain, by Keychain account.
    private static let legacyAccounts = ["openai-api-key": openAI, "gemini-api-key": gemini]

    /// The first time, keys are read from the Keychain (this may ask for the
    /// password one last time), saved here, and the Keychain items deleted.
    private static func migrateIfNeeded() {
        guard !migrated else { return }
        migrated = true
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        var found: [String: String] = [:]
        for (account, name) in legacyAccounts {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: "Ilan Voice",
                                        kSecAttrAccount as String: account]
            var lookup = query
            lookup[kSecReturnData as String] = true
            lookup[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { continue }
            found[name] = key
            SecItemDelete(query as CFDictionary)
        }
        if !found.isEmpty { write(found) }
    }
}
