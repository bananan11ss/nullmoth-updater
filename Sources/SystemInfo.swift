import Foundation

struct SystemInfo {
    var macOS = ""
    var build = ""
    var gpu = "—"
    var vram = ""
    var loadedKexts: [String] = []
    var onBattery = false
    var powerLine = ""
    var installedVersion: String?   // nil = unknown (state folder is root-only)
    var bundleInstalled = false

    static let expectedKexts = ["com.nullmoth.NVRM", "com.nullmoth.NVAccel", "com.nullmoth.NVRMFB", "com.nullmoth.NVRMAGDC"]

    var driverLoaded: Bool { Set(Self.expectedKexts).isSubset(of: Set(loadedKexts)) }

    static func collect() -> SystemInfo {
        var s = SystemInfo()
        let pi = ProcessInfo.processInfo.operatingSystemVersion
        s.macOS = "\(pi.majorVersion).\(pi.minorVersion).\(pi.patchVersion)"
        s.build = Shell.run("/usr/bin/sw_vers", ["-buildVersion"]).output.trimmingCharacters(in: .whitespacesAndNewlines)

        let sp = Shell.run("/usr/sbin/system_profiler", ["SPDisplaysDataType", "-json"], timeout: 30, stderr: false)
        if let data = sp.output.data(using: .utf8),
           let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cards = j["SPDisplaysDataType"] as? [[String: Any]] {
            let name: ([String: Any]) -> String = { ($0["sppci_model"] as? String) ?? ($0["_name"] as? String) ?? "" }
            let nv = cards.first { ($0["spdisplays_vendor"] as? String ?? "").contains("10de") || name($0).contains("NVIDIA") }
            if let nv {
                s.gpu = name(nv).isEmpty ? "NVIDIA" : name(nv)
                s.vram = (nv["spdisplays_vram"] as? String) ?? (nv["_spdisplays_vram"] as? String) ?? ""
            }
        }

        let km = Shell.run("/usr/bin/kmutil", ["showloaded", "--list-only"], timeout: 30)
        s.loadedKexts = km.output.split(separator: "\n").compactMap { line in
            line.split(separator: " ").map(String.init).first { $0.hasPrefix("com.nullmoth.") }
        }

        let batt = Shell.run("/usr/bin/pmset", ["-g", "batt"]).output
        s.onBattery = batt.contains("'Battery Power'")
        s.powerLine = batt.split(separator: "\n").dropFirst().first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""

        s.bundleInstalled = FileManager.default.fileExists(atPath: "/Library/GPUBundles/NVMTLDriver.bundle")
        s.installedVersion = readInstalledVersion()
        return s
    }

    /// /Library/NullMoth is root-only (0700) on installs made by the 1401 app, so a normal process
    /// usually cannot read driver-version. Fall back to the copy this updater keeps after it installs.
    static func readInstalledVersion() -> String? {
        if let v = try? String(contentsOfFile: "/Library/NullMoth/driver-version", encoding: .utf8) {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        if let v = try? String(contentsOf: Paths.cachedVersion, encoding: .utf8) {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return nil
    }
}

enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("NullMothUpdater", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }()
    static var cachedVersion: URL { support.appendingPathComponent("installed-version") }
    static let logs: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Logs/NullMothUpdater", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}

enum Version {
    static func key(_ v: String) -> [Int] {
        v.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0) ?? 0 }
    }
    static func newer(_ a: String, than b: String) -> Bool {
        let x = key(a), y = key(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}
