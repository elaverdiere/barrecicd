import Foundation

/// One watched project. Everything here is plain text the user can edit and commit (F03-AC1) —
/// deliberately not a preferences blob, so a broken setup can be diffed and fixed in an editor.
public struct ProjectConfig: Sendable, Equatable {
    public var name: String
    public var provider: String        // gitea · github · gitlab
    public var host: String
    public var repo: String            // owner/repo, or a numeric project id for GitLab
    public var branch: String
    public var ledger: String?
    public var logs: String?

    public init(name: String, provider: String, host: String, repo: String, branch: String,
                ledger: String? = nil, logs: String? = nil) {
        self.name = name; self.provider = provider; self.host = host; self.repo = repo
        self.branch = branch; self.ledger = ledger; self.logs = logs
    }
}

/// How several projects occupy the menu bar (F03-AC2). Settled by the owner 2026-08-12.
public enum DisplayMode: String, Sendable, Equatable {
    /// One menu-bar item per project — the default.
    case perProject = "per-project"
    /// A single item carrying the worst state across them.
    case combined
}

public enum ConfigError: Error, CustomStringConvertible {
    case unreadable(String)
    case empty(String)
    public var description: String {
        switch self {
        case .unreadable(let p): return "no config at \(p)"
        case .empty(let p): return "\(p) declares no project"
        }
    }
}

public enum ConfigReader {

    public static var defaultPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".config/barrecicd/projects.conf")
    }

    /// A deliberately small INI: `[name]` opens a project, `key = value` fills it. Unknown keys are
    /// IGNORED rather than fatal — a config file that refuses to load because of one stray line
    /// would take the whole indicator down, which is the outage it is supposed to report.
    public static func parse(_ text: String) -> [ProjectConfig] {
        var out: [ProjectConfig] = []
        var name: String?
        var kv: [String: String] = [:]

        func flush() {
            guard let n = name else { return }
            // A project missing an essential field is dropped rather than half-built: F03-AC3 wants
            // one bad project not to disturb the others, and a half-built one disturbs them loudly.
            guard let repo = kv["repo"], let host = kv["host"] else { name = nil; kv = [:]; return }
            out.append(ProjectConfig(name: n,
                                     provider: (kv["provider"] ?? "gitea").lowercased(),
                                     host: host.hasSuffix("/") ? String(host.dropLast()) : host,
                                     repo: repo,
                                     branch: kv["branch"] ?? "main",
                                     ledger: kv["ledger"], logs: kv["logs"]))
            name = nil; kv = [:]
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                flush()
                name = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { kv[k] = v }
        }
        flush()
        return out
    }

    /// Skeleton: compiles, always answers the default. The behaviour lands in the green commit.
    public static func parseDisplay(_ text: String) -> DisplayMode {
        _ = text
        return .perProject
    }

    public static func load(path: String? = nil) throws -> [ProjectConfig] {
        let p = (path ?? defaultPath as String)
        guard let text = try? String(contentsOfFile: (p as NSString).expandingTildeInPath, encoding: .utf8) else {
            throw ConfigError.unreadable(p)
        }
        let projects = parse(text)
        if projects.isEmpty { throw ConfigError.empty(p) }
        return projects
    }

    /// Written on first launch so the app explains itself instead of showing an empty menu.
    public static let sample = """
    # barrecicd — one block per watched project. Tokens are NOT stored here; they live in the
    # Keychain (service "barrecicd", account = the project name below):
    #
    #   security add-generic-password -s barrecicd -a my-project -w '<token>'
    #
    # provider : gitea | github | gitlab
    # host     : the API root's origin (https://api.github.com for GitHub)
    # repo     : owner/repo — or the numeric project id for GitLab
    # ledger   : optional. A directory your pipeline writes as it goes; gives the per-gate table.
    # logs     : optional. Where the gates' captured output lives, so a failed row can open it.

    # If the host is already in your ~/.netrc, or if it is github.com and you use the GitHub CLI,
    # there is nothing to add: the app reads those stores before asking for anything of its own.

    [my-project]
    provider = gitea
    host     = https://gitea.example.com
    repo     = owner/repo
    branch   = main
    ledger   = ~/.cache/my-ci/live
    logs     = ~/.cache/my-ci/logs
    """
}
