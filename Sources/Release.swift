import CryptoKit
import Foundation

struct Release {
    let version: String
    let tag: String
    let published: String
    let notes: String
    let packageName: String
    let packageURL: URL
    let packageSize: Int64
    let sha256: String
}

enum ReleaseError: LocalizedError {
    case network(String)
    case format(String)
    var errorDescription: String? {
        switch self {
        case .network(let s): return "Сеть: \(s)"
        case .format(let s): return s
        }
    }
}

enum ReleaseService {
    static let repo = "nullmoth/nvidia-macos-driver"
    static let mirror = "https://nullmothsystems.com/mirror/"

    static func driverVersion(fromAsset name: String) -> String? {
        guard name.hasPrefix("nullmoth-nvidia-"), name.hasSuffix(".tar.gz") else { return nil }
        let v = String(name.dropFirst("nullmoth-nvidia-".count).dropLast(".tar.gz".count))
        return v.range(of: #"^[0-9]+\.[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil ? v : nil
    }

    static func fetchJSON(_ url: URL) async throws -> Any {
        var rq = URLRequest(url: url, timeoutInterval: 30)
        rq.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        rq.setValue("NullMothUpdater", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: rq)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw ReleaseError.network("HTTP \(code) от \(url.host ?? "")") }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// The newest releases that carry a driver package, newest first.
    static func fetchReleases(limit: Int = 8) async throws -> [Release] {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=\(limit)")!
        guard let list = try await fetchJSON(url) as? [[String: Any]] else { throw ReleaseError.format("неожиданный ответ GitHub") }
        var out: [Release] = []
        for r in list {
            if (r["draft"] as? Bool) == true { continue }
            guard let assets = r["assets"] as? [[String: Any]] else { continue }
            var pkg: (String, String, URL, Int64)?
            var sums: URL?
            for a in assets {
                guard let n = a["name"] as? String,
                      let u = (a["browser_download_url"] as? String).flatMap(URL.init(string:)), u.scheme == "https" else { continue }
                if n == "SHA256SUMS.txt" { sums = u }
                if let v = driverVersion(fromAsset: n) { pkg = (v, n, u, (a["size"] as? NSNumber)?.int64Value ?? 0) }
            }
            guard let pkg, let sums else { continue }
            let sha = try await shaFromSums(sums, for: pkg.1)
            out.append(Release(version: pkg.0, tag: r["tag_name"] as? String ?? pkg.0,
                               published: String((r["published_at"] as? String ?? "").prefix(10)),
                               notes: r["body"] as? String ?? "", packageName: pkg.1, packageURL: pkg.2,
                               packageSize: pkg.3, sha256: sha))
        }
        guard !out.isEmpty else { throw ReleaseError.format("в релизах нет пакета драйвера") }
        return out.sorted { Version.newer($0.version, than: $1.version) }
    }

    static func shaFromSums(_ url: URL, for name: String) async throws -> String {
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw ReleaseError.network("не удалось скачать SHA256SUMS.txt") }
        let txt = String(decoding: data, as: UTF8.self)
        for line in txt.split(separator: "\n") {
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if f.count >= 2, String(f.last!).trimmingCharacters(in: CharacterSet(charactersIn: "*")) == name {
                let h = String(f[0]).lowercased()
                if h.count == 64 { return h }
            }
        }
        throw ReleaseError.format("SHA256SUMS.txt не содержит \(name)")
    }

    static func sha256(of file: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            let chunk = h.readData(ofLength: 4 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Downloads one file with progress reporting.
final class Downloader: NSObject, URLSessionDownloadDelegate {
    private var continuation: CheckedContinuation<URL, Error>?
    private let destination: URL
    private let progress: (Int64, Int64) -> Void
    private var session: URLSession!

    init(destination: URL, progress: @escaping (Int64, Int64) -> Void) {
        self.destination = destination
        self.progress = progress
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 60 * 60
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    func download(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { c in
            continuation = c
            session.downloadTask(with: url).resume()
        }
    }

    func cancel() { session.invalidateAndCancel() }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            continuation?.resume(throwing: ReleaseError.network("HTTP \(code)")); continuation = nil; return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            continuation?.resume(returning: destination)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation?.resume(throwing: ReleaseError.network(error.localizedDescription)); continuation = nil }
        s.finishTasksAndInvalidate()
    }
}
