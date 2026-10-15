import Foundation

enum FetchError: LocalizedError {
    case http(String), checksum(String), missing(String)
    var errorDescription: String? {
        switch self {
        case .http(let s): return "Загрузка: \(s)"
        case .checksum(let s): return "Контрольная сумма не сошлась: \(s)"
        case .missing(let s): return s
        }
    }
}

/// Downloads with SHA-256 checks into a work folder and unpacks zips.
final class Fetcher {
    let work: URL
    private var buildRepo: [String: (url: String, sha: String, version: String)]?
    var log: (String) -> Void = { _ in }

    init(work: URL) { self.work = work }

    private func get(_ url: String) async throws -> Data {
        guard let u = URL(string: url) else { throw FetchError.http("плохой адрес \(url)") }
        var rq = URLRequest(url: u, timeoutInterval: 120)
        rq.setValue("NullMothUpdater", forHTTPHeaderField: "User-Agent")
        let (d, r) = try await URLSession.shared.data(for: rq)
        let code = (r as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw FetchError.http("HTTP \(code) — \(u.lastPathComponent)") }
        return d
    }

    private func sha256(_ d: Data) -> String {
        let tmp = work.appendingPathComponent("sha.tmp")
        try? d.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return ReleaseService.sha256(of: tmp) ?? ""
    }

    /// dortania/build-repo: the nightly builds 1401 and most guides use, each with a SHA-256.
    func buildRepoEntry(_ name: String) async throws -> (url: String, sha: String, version: String) {
        if buildRepo == nil {
            let d = try await get("https://raw.githubusercontent.com/dortania/build-repo/builds/config.json")
            guard let j = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw FetchError.http("build-repo: неожиданный ответ") }
            var m: [String: (String, String, String)] = [:]
            for (k, v) in j {
                guard let e = v as? [String: Any], let vs = e["versions"] as? [[String: Any]], let v0 = vs.first,
                      let links = v0["links"] as? [String: String], let url = links["release"],
                      let hashes = v0["hashes"] as? [String: Any], let rel = hashes["release"] as? [String: String], let sha = rel["sha256"] else { continue }
                m[k] = (url, sha.lowercased(), v0["version"] as? String ?? "")
            }
            buildRepo = m
        }
        guard let e = buildRepo?[name] else { throw FetchError.missing("в build-repo нет \(name)") }
        return e
    }

    func githubAsset(repo: String, pattern: String) async throws -> (url: String, version: String) {
        let d = try await get("https://api.github.com/repos/\(repo)/releases/latest")
        guard let j = try JSONSerialization.jsonObject(with: d) as? [String: Any], let assets = j["assets"] as? [[String: Any]] else {
            throw FetchError.http("\(repo): нет релиза")
        }
        for a in assets {
            if let n = a["name"] as? String, n.range(of: pattern, options: .regularExpression) != nil, let u = a["browser_download_url"] as? String {
                return (u, j["tag_name"] as? String ?? "")
            }
        }
        throw FetchError.missing("\(repo): в релизе нет файла по шаблону \(pattern)")
    }

    /// Downloads a zip (verifying `sha` when given) and unpacks it; returns the folder.
    func zip(_ url: String, sha: String?, as name: String) async throws -> URL {
        let d = try await get(url)
        let got = sha256(d)
        if let sha, got != sha { throw FetchError.checksum("\(name): ожидалось \(sha.prefix(12))…, получено \(got.prefix(12))…") }
        let z = work.appendingPathComponent("\(name).zip"), out = work.appendingPathComponent(name)
        try d.write(to: z)
        try? FileManager.default.removeItem(at: out)
        let r = Shell.run("/usr/bin/ditto", ["-x", "-k", z.path, out.path], timeout: 300)
        guard r.status == 0 else { throw FetchError.http("распаковка \(name): \(r.output)") }
        log("   \(name): \(sha != nil ? "SHA-256 совпал" : "без контрольной суммы (GitHub release)")")
        return out
    }

    /// Finds a top-level kext bundle with this name anywhere in an unpacked folder (not inside another kext or a dSYM).
    static func find(_ bundle: String, in dir: URL) -> URL? {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        for case let u as URL in e {
            let p = u.path
            if p.contains(".dSYM") { e.skipDescendants(); continue }
            if u.lastPathComponent == bundle { return u }
            if u.pathExtension == "kext" { e.skipDescendants() }
        }
        return nil
    }
}
