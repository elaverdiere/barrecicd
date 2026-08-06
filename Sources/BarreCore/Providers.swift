import Foundation

/// A provider answers two questions per project and nothing more (S001 §3.1): what is the tip of
/// the watched branch, and what is the newest run. Keeping it to two is what lets a new CI be
/// supported in an afternoon.
public protocol Provider: Sendable {
    func fetch(_ project: ProjectConfig, credential: Credential?, transport: Transport) async -> RunState
}

/// Injected so the providers can be exercised against a stub server (S001 §7, Q3) without a network.
public protocol Transport: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> (Int, Data)
}

public struct URLSessionTransport: Transport {
    let session: URLSession
    public init(timeout: TimeInterval = 8) {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.waitsForConnectivity = false
        self.session = URLSession(configuration: c)
    }
    public func get(_ url: URL, headers: [String: String]) async throws -> (Int, Data) {
        var r = URLRequest(url: url)
        // A User-Agent, always. Measured: its absence was one of three faults that all produced the
        // SAME grey badge blaming an unreachable API that was in fact answering 200.
        r.setValue("barrecicd", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await session.data(for: r)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

// MARK: - Shared helpers

enum ProviderKit {
    /// The branch name goes in a PATH segment and branches legitimately contain `/`
    /// (`release/1.2`). Leaving it unencoded produced a 404 that read as "no run for this commit".
    static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? s
    }

    static func json(_ data: Data) -> Any? { try? JSONSerialization.jsonObject(with: data) }

    /// F05-AC2 — a rejected token is grey with the cause named, never red. An authentication fault
    /// is a fact about the credential, not a verdict on the code.
    static func failure(_ project: String, _ code: Int, hadToken: Bool) -> String {
        switch code {
        case 401, 403: return "token refused (HTTP \(code))"
        case 404:
            // Measured against a real private Gitea repo, 2026-08-06: a private repository answers
            // 404 to an unauthenticated caller — deliberately, so that its existence does not leak.
            // So 404 WITHOUT a token is far more often a missing credential than a typo, and saying
            // "check host, repo and branch" would send the reader to audit a config that is correct.
            return hadToken ? "not found (HTTP 404) — check host, repo and branch"
                            : "no token for this project — a private repo answers 404 to a stranger"
        case 0:        return "CI host unreachable"
        default:       return "CI host answered HTTP \(code)"
        }
    }

    static func status(_ raw: String, conclusion: String?) -> RunStatus {
        let s = raw.lowercased(), c = (conclusion ?? "").lowercased()
        if ["queued", "waiting", "in_progress", "running", "pending", "created", "preparing"].contains(s) { return .running }
        if ["success", "succeeded", "completed"].contains(c) || s == "success" { return .success }
        if ["failure", "failed", "error", "cancelled", "canceled", "timed_out"].contains(c) { return .failure }
        if ["failure", "failed", "error", "cancelled", "canceled"].contains(s) { return .failure }
        return .unknown
    }
}

// MARK: - Gitea

public struct GiteaProvider: Provider {
    public init() {}
    public func fetch(_ p: ProjectConfig, credential: Credential?, transport: Transport) async -> RunState {
        var h: [String: String] = ["Accept": "application/json"]
        if let credential { let (k, v) = credential.header(forProvider: "gitea"); h[k] = v }
        var out = RunState(project: p.name)

        guard let bURL = URL(string: "\(p.host)/api/v1/repos/\(p.repo)/branches/\(ProviderKit.encode(p.branch))") else {
            out.unreachable = "malformed host or repo in the config"; return out
        }
        do {
            let (code, data) = try await transport.get(bURL, headers: h)
            guard code == 200, let o = ProviderKit.json(data) as? [String: Any],
                  let commit = o["commit"] as? [String: Any], let id = commit["id"] as? String else {
                out.unreachable = ProviderKit.failure(p.name, code, hadToken: credential != nil); return out
            }
            out.tipSHA = id
        } catch { out.unreachable = "CI host unreachable"; return out }

        guard let rURL = URL(string: "\(p.host)/api/v1/repos/\(p.repo)/actions/runs?limit=1") else { return out }
        do {
            let (code, data) = try await transport.get(rURL, headers: h)
            guard code == 200, let o = ProviderKit.json(data) as? [String: Any],
                  let runs = o["workflow_runs"] as? [[String: Any]], let r = runs.first else {
                // Reachable, but with no run at all — that is "nothing is watching", not an outage.
                return out
            }
            out.headSHA = (r["head_sha"] as? String) ?? ""
            out.number = (r["run_number"] as? Int) ?? (r["id"] as? Int)
            out.status = ProviderKit.status((r["status"] as? String) ?? "", conclusion: r["conclusion"] as? String)
            if let n = out.number { out.url = "\(p.host)/\(p.repo)/actions/runs/\(n)" }
        } catch { out.unreachable = "CI host unreachable" }
        return out
    }
}

// MARK: - GitHub

public struct GitHubProvider: Provider {
    public init() {}
    public func fetch(_ p: ProjectConfig, credential: Credential?, transport: Transport) async -> RunState {
        var h: [String: String] = ["Accept": "application/vnd.github+json"]
        if let credential { let (k, v) = credential.header(forProvider: "github"); h[k] = v }
        var out = RunState(project: p.name)
        let host = p.host.isEmpty ? "https://api.github.com" : p.host

        guard let cURL = URL(string: "\(host)/repos/\(p.repo)/commits/\(ProviderKit.encode(p.branch))") else {
            out.unreachable = "malformed host or repo in the config"; return out
        }
        do {
            let (code, data) = try await transport.get(cURL, headers: h)
            guard code == 200, let o = ProviderKit.json(data) as? [String: Any], let sha = o["sha"] as? String else {
                out.unreachable = ProviderKit.failure(p.name, code, hadToken: credential != nil); return out
            }
            out.tipSHA = sha
        } catch { out.unreachable = "CI host unreachable"; return out }

        guard let rURL = URL(string: "\(host)/repos/\(p.repo)/actions/runs?branch=\(ProviderKit.encode(p.branch))&per_page=1") else { return out }
        do {
            let (code, data) = try await transport.get(rURL, headers: h)
            guard code == 200, let o = ProviderKit.json(data) as? [String: Any],
                  let runs = o["workflow_runs"] as? [[String: Any]], let r = runs.first else { return out }
            out.headSHA = (r["head_sha"] as? String) ?? ""
            out.number = r["run_number"] as? Int
            out.status = ProviderKit.status((r["status"] as? String) ?? "", conclusion: r["conclusion"] as? String)
            out.url = r["html_url"] as? String
        } catch { out.unreachable = "CI host unreachable" }
        return out
    }
}

// MARK: - GitLab

public struct GitLabProvider: Provider {
    public init() {}
    public func fetch(_ p: ProjectConfig, credential: Credential?, transport: Transport) async -> RunState {
        var h: [String: String] = ["Accept": "application/json"]
        if let credential { let (k, v) = credential.header(forProvider: "gitlab"); h[k] = v }
        var out = RunState(project: p.name)
        let host = p.host.isEmpty ? "https://gitlab.com" : p.host
        // GitLab wants the project id, or the path FULLY url-encoded including its slashes.
        let id = Int(p.repo) != nil ? p.repo : (p.repo.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? p.repo)

        guard let bURL = URL(string: "\(host)/api/v4/projects/\(id)/repository/branches/\(ProviderKit.encode(p.branch))") else {
            out.unreachable = "malformed host or repo in the config"; return out
        }
        do {
            let (code, data) = try await transport.get(bURL, headers: h)
            guard code == 200, let o = ProviderKit.json(data) as? [String: Any],
                  let commit = o["commit"] as? [String: Any], let sha = commit["id"] as? String else {
                out.unreachable = ProviderKit.failure(p.name, code, hadToken: credential != nil); return out
            }
            out.tipSHA = sha
        } catch { out.unreachable = "CI host unreachable"; return out }

        guard let rURL = URL(string: "\(host)/api/v4/projects/\(id)/pipelines?ref=\(ProviderKit.encode(p.branch))&per_page=1") else { return out }
        do {
            let (code, data) = try await transport.get(rURL, headers: h)
            guard code == 200, let arr = ProviderKit.json(data) as? [[String: Any]], let r = arr.first else { return out }
            out.headSHA = (r["sha"] as? String) ?? ""
            out.number = r["iid"] as? Int ?? r["id"] as? Int
            out.status = ProviderKit.status((r["status"] as? String) ?? "", conclusion: nil)
            out.url = r["web_url"] as? String
        } catch { out.unreachable = "CI host unreachable" }
        return out
    }
}

public enum Providers {
    public static func make(_ name: String) -> Provider {
        switch name.lowercased() {
        case "github": return GitHubProvider()
        case "gitlab": return GitLabProvider()
        default:       return GiteaProvider()
        }
    }
}
