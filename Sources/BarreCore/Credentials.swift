import Foundation

/// How a request proves who it is. Two shapes, because the stores that already exist on a developer
/// machine hold two shapes: a personal access token, or a login/password pair.
public enum Credential: Sendable, Equatable {
    case token(String)
    case basic(user: String, password: String)

    /// The header this credential produces, per provider family.
    public func header(forProvider provider: String) -> (String, String) {
        switch self {
        case .token(let t):
            switch provider.lowercased() {
            case "github": return ("Authorization", "Bearer \(t)")
            case "gitlab": return ("PRIVATE-TOKEN", t)
            default:       return ("Authorization", "token \(t)")
            }
        case .basic(let u, let p):
            let raw = Data("\(u):\(p)".utf8).base64EncodedString()
            return ("Authorization", "Basic \(raw)")
        }
    }
}

/// A `~/.netrc` reader.
///
/// This exists because the alternative was worse. The app first asked the user to copy a token it
/// could already reach: the machine hosting the watched CI was already in `~/.netrc`, used every day
/// by `curl` and by the rest of the toolchain. Asking for a copy would have multiplied the places a
/// secret lives — and a secret in two stores is a secret that gets rotated in one of them.
///
/// Parsing is deliberately dumb and matches the format's own grammar: a flat token stream where
/// `machine`, `login`, `password`, `account` and `default` are keywords and everything else is a
/// value. `macdef` is skipped to end-of-blank-line, as the format requires.
public enum NetrcReader {

    public static func credential(forHost host: String, path: String? = nil) -> Credential? {
        let p = path ?? (NSHomeDirectory() as NSString).appendingPathComponent(".netrc")
        guard let text = try? String(contentsOfFile: p, encoding: .utf8) else { return nil }
        return parse(text)[host].flatMap { entry in
            guard let user = entry.login, let password = entry.password else { return nil }
            return .basic(user: user, password: password)
        }
    }

    public struct Entry: Equatable, Sendable {
        public var login: String?
        public var password: String?
    }

    public static func parse(_ text: String) -> [String: Entry] {
        var out: [String: Entry] = [:]
        var current: String?
        var entry = Entry()
        var skippingMacro = false

        func flush() {
            if let c = current { out[c] = entry }
            current = nil; entry = Entry()
        }

        var tokens: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if skippingMacro {
                // A `macdef` body runs until a blank line. Its contents are shell commands and must
                // never be read as keywords, or a macro mentioning "password" would poison an entry.
                if line.trimmingCharacters(in: .whitespaces).isEmpty { skippingMacro = false }
                continue
            }
            let t = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if t.first == "macdef" { skippingMacro = true; continue }
            tokens.append(contentsOf: t)
        }

        var i = 0
        while i < tokens.count {
            switch tokens[i] {
            case "machine":
                flush()
                if i + 1 < tokens.count { current = tokens[i + 1]; i += 1 }
            case "default":
                flush()
                current = "default"
            case "login":
                if i + 1 < tokens.count { entry.login = tokens[i + 1]; i += 1 }
            case "password":
                if i + 1 < tokens.count { entry.password = tokens[i + 1]; i += 1 }
            case "account":
                i += 1
            default:
                break
            }
            i += 1
        }
        flush()
        return out
    }
}

/// Resolves a project's credential from the stores a developer machine already has, in order of how
/// deliberate each one is.
///
/// F05-AC1 keeps its meaning: nothing here reads a secret out of the CONFIG FILE, which is the file
/// meant to be committed. What changed is that the app no longer pretends the Keychain is the only
/// place a credential may already live.
public enum CredentialStore {

    /// Cached because resolving can spawn a subprocess, and polling runs every twenty seconds
    /// forever. A credential that changes needs "Refresh now", which reloads everything anyway.
    private static let cache = Cache()

    final class Cache: @unchecked Sendable {
        private var store: [String: Credential] = [:]
        private let lock = NSLock()
        func get(_ k: String) -> Credential? { lock.lock(); defer { lock.unlock() }; return store[k] }
        func set(_ k: String, _ v: Credential) { lock.lock(); store[k] = v; lock.unlock() }
        func clear() { lock.lock(); store.removeAll(); lock.unlock() }
    }

    public static func forget() { cache.clear() }

    public static func resolve(project: ProjectConfig) -> Credential? {
        if let hit = cache.get(project.name) { return hit }
        guard let found = lookup(project) else { return nil }
        cache.set(project.name, found)
        return found
    }

    private static func lookup(_ project: ProjectConfig) -> Credential? {
        // 1. The Keychain entry the user created ON PURPOSE for this app. It wins, always: an
        //    explicit choice must never be silently overridden by something found lying around.
        if let t = Keychain.token(forProject: project.name) { return .token(t) }

        // 2. ~/.netrc, keyed on the host from the config. The same store curl and git already use.
        if let host = URLComponents(string: project.host)?.host,
           let c = NetrcReader.credential(forHost: host) {
            return c
        }

        // 3. github.com only: the GitHub CLI already holds a token in the system keyring, and asking
        //    the user to paste a second copy of it would be asking them to weaken their own setup.
        if project.provider.lowercased() == "github" || (URLComponents(string: project.host)?.host ?? "").hasSuffix("github.com"),
           let t = ghToken() {
            return .token(t)
        }
        return nil
    }

    /// Asks `gh` for its token. Never parses the keyring itself — the CLI owns that format, and
    /// reading someone else's private storage layout is how a tool breaks on their next release.
    private static func ghToken() -> String? {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        guard let bin = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["auth", "token"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let t = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t?.isEmpty == false) ? t : nil
    }
}
