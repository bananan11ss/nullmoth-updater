import Foundation

struct BuildResult {
    let efi: URL                 // …/EFI
    let report: String
    let validated: Bool
}

/// Builds an EFI folder from scratch for the machine this runs on. It never writes to a boot partition: the result is
/// a folder the user copies to a USB stick and boots from to test, with the working EFI left alone.
final class EFIBuilder {
    var log: (String) -> Void = { print($0) }
    let acpiDir: URL                 // the compiled SSDTs shipped with the app

    init(acpiDir: URL) { self.acpiDir = acpiDir }

    static var outputRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenCore-Builds", isDirectory: true)
    }

    func run(current: CurrentEFI?, output: URL? = nil) async throws -> BuildResult {
        let fm = FileManager.default
        let stamp: String = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"; return f.string(from: Date()) }()
        let base = output ?? Self.outputRoot.appendingPathComponent(stamp)
        let efi = base.appendingPathComponent("EFI"), oc = efi.appendingPathComponent("OC")
        let work = fm.temporaryDirectory.appendingPathComponent("efibuild-\(stamp)")
        try? fm.removeItem(at: base); try? fm.removeItem(at: work)
        for d in ["EFI/BOOT", "EFI/OC/ACPI", "EFI/OC/Drivers", "EFI/OC/Kexts", "EFI/OC/Tools"] {
            try fm.createDirectory(at: base.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let fetch = Fetcher(work: work); fetch.log = log

        log("== 1. Железо")
        let h = HardwareDetector.detect()
        log("   \(h.cpuBrand) · \(h.cpuName) · \(h.isLaptop ? "ноутбук" : "ПК") · \(h.memoryGB) ГБ")
        var plan = Planner.plan(h, current: current)
        var notes = plan.notes
        log("   текущая EFI: \(current.map { $0.root.path } ?? "не прочитана")")

        log("== 2. OpenCore")
        let ocEntry = try await fetch.buildRepoEntry("OpenCorePkg")
        let ocDir = try await fetch.zip(ocEntry.url, sha: ocEntry.sha, as: "OpenCorePkg")
        log("   OpenCore \(ocEntry.version)")
        let x64 = ocDir.appendingPathComponent("X64/EFI")
        try fm.copyItem(at: x64.appendingPathComponent("BOOT/BOOTx64.efi"), to: efi.appendingPathComponent("BOOT/BOOTx64.efi"))
        try fm.copyItem(at: x64.appendingPathComponent("OC/OpenCore.efi"), to: oc.appendingPathComponent("OpenCore.efi"))

        // drivers: OpenCore's, plus any extra ones the current EFI loads (its HfsPlus replaces OpenHfsPlus)
        var drivers = plan.drivers
        if let cur = current, let list = cur.value("UEFI/Drivers") as? [[String: Any]] {
            for d in list where (d["Enabled"] as? Bool) == true {
                guard let path = d["Path"] as? String, !drivers.contains(path), cur.drivers.contains(path) else { continue }
                if fm.fileExists(atPath: x64.appendingPathComponent("OC/Drivers/\(path)").path) { drivers.append(path); continue }
                try? fm.copyItem(at: cur.oc.appendingPathComponent("Drivers/\(path)"), to: oc.appendingPathComponent("Drivers/\(path)"))
                drivers.append(path); notes.append("Драйвер \(path) перенесён из текущей EFI.")
            }
            if drivers.contains("HfsPlus.efi") { drivers.removeAll { $0 == "OpenHfsPlus.efi" } }
        }
        for d in drivers where !fm.fileExists(atPath: oc.appendingPathComponent("Drivers/\(d)").path) {
            try fm.copyItem(at: x64.appendingPathComponent("OC/Drivers/\(d)"), to: oc.appendingPathComponent("Drivers/\(d)"))
        }

        log("== 3. Кексты")
        var entries: [KextEntry] = []
        var installed: [(String, String)] = []
        for pick in plan.kexts {
            var src: URL?
            switch pick.source {
            case .buildRepo(let name):
                do { let e = try await fetch.buildRepoEntry(name); src = try await fetch.zip(e.url, sha: e.sha, as: name) }
                catch { plan.warnings.append("\(pick.bundles.joined(separator: ", ")): \(error.localizedDescription)"); continue }
            case .github(let repo, let pattern):
                do { let a = try await fetch.githubAsset(repo: repo, pattern: pattern); src = try await fetch.zip(a.url, sha: nil, as: repo.replacingOccurrences(of: "/", with: "_")) }
                catch { plan.warnings.append("\(pick.bundles.joined(separator: ", ")): \(error.localizedDescription)"); continue }
            case .url(let u, let sha):
                do { src = try await fetch.zip(u, sha: sha, as: pick.bundles[0]) }
                catch { plan.warnings.append("\(pick.bundles[0]): \(error.localizedDescription)"); continue }
            case .current:
                src = current?.oc.appendingPathComponent("Kexts")
            }
            guard let from = src else { continue }
            for b in pick.bundles {
                guard let bundle = Fetcher.find(b, in: from) else { plan.warnings.append("\(b) не найден в загрузке"); continue }
                let dest = oc.appendingPathComponent("Kexts/\(b)")
                try? fm.removeItem(at: dest)
                try fm.copyItem(at: bundle, to: dest)
                installed.append((b, pick.reason))
                entries += kextEntries(dest, relative: b, pick: pick, current: current)
            }
        }
        let ordered = KextEntry.ordered(entries)
        for (b, why) in installed { log("   \(b) — \(why)") }

        log("== 4. ACPI")
        var ssdts: [String] = []
        for s in plan.ssdts {
            let from = acpiDir.appendingPathComponent(s.file)
            guard fm.fileExists(atPath: from.path) else { plan.warnings.append("\(s.file) нет в приложении"); continue }
            // the EC variants carry their path in the file name; inside the EFI it is just SSDT-EC.aml
            let name = s.file.hasPrefix("SSDT-EC-LAPTOP") ? "SSDT-EC.aml" : s.file.replacingOccurrences(of: #"-(PC00|PCI0)\.aml$"#, with: ".aml", options: .regularExpression)
            try fm.copyItem(at: from, to: oc.appendingPathComponent("ACPI/\(name)"))
            ssdts.append(name)
            log("   \(name) — \(s.reason)")
        }

        // tools the current config lists (the NullMoth "Remove NVIDIA driver" entry among them)
        var tools: [[String: Any]] = []
        if let cur = current, let list = cur.value("Misc/Tools") as? [[String: Any]] {
            for t in list {
                guard let path = t["Path"] as? String, cur.tools.contains(path) else { continue }
                try? fm.copyItem(at: cur.oc.appendingPathComponent("Tools/\(path)"), to: oc.appendingPathComponent("Tools/\(path)"))
                tools.append(t)
            }
            if !tools.isEmpty { notes.append("Инструменты в меню OpenCore перенесены: \(tools.compactMap { $0["Path"] as? String }.joined(separator: ", ")).") }
        }

        log("== 5. config.plist")
        let macserial = ocDir.appendingPathComponent("Utilities/macserial/macserial")
        let config = try ConfigBuilder.make(sample: ocDir.appendingPathComponent("Docs/Sample.plist"), h: h, plan: plan, kexts: ordered,
                                            ssdts: ssdts, drivers: drivers, tools: tools, current: current,
                                            macserial: fm.isExecutableFile(atPath: macserial.path) ? macserial : nil, notes: &notes)
        let xml = try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0)
        try xml.write(to: oc.appendingPathComponent("config.plist"))

        log("== 6. Проверка ocvalidate")
        let ov = ocDir.appendingPathComponent("Utilities/ocvalidate/ocvalidate")
        let v = Shell.run(ov.path, [oc.appendingPathComponent("config.plist").path], timeout: 60)
        let validated = v.status == 0 && v.output.contains("No issues found")
        log(validated ? "   ocvalidate: замечаний нет" : "   ocvalidate нашёл проблемы:\n" + v.output)

        let report = Report.make(h: h, plan: plan, notes: notes, installed: installed, kexts: ordered, ssdts: ssdts, drivers: drivers,
                                 oc: ocEntry.version, config: config, current: current, validate: v.output, validated: validated)
        try report.write(to: base.appendingPathComponent("ОТЧЁТ.txt"), atomically: true, encoding: .utf8)
        log("== Готово: \(efi.path)")
        return BuildResult(efi: efi, report: report, validated: validated)
    }

    /// Kernel → Add entries for a kext and the plug-ins inside it. A kext taken from the current EFI keeps that
    /// config's entries (their MinKernel, MaxKernel and Enabled are this machine's choices).
    private func kextEntries(_ bundle: URL, relative: String, pick: KextPick, current: CurrentEFI?) -> [KextEntry] {
        var out: [KextEntry] = []
        let curList = (current?.value("Kernel/Add") as? [[String: Any]]) ?? []
        func add(_ url: URL, _ rel: String) {
            let name = url.lastPathComponent
            let curEntry = curList.first { ($0["BundlePath"] as? String) == rel }
            var enabled = !pick.dropPlugins.contains(name)
            if case .current = pick.source, let ce = curEntry { enabled = ce["Enabled"] as? Bool ?? enabled }
            if case .current = pick.source, curEntry == nil, rel.contains("/PlugIns/") { enabled = false }
            guard var e = KextEntry.read(url, relative: rel, comment: name.replacingOccurrences(of: ".kext", with: ""), enabled: enabled) else { return }
            if let ce = curEntry { e.minKernel = ce["MinKernel"] as? String ?? ""; e.maxKernel = ce["MaxKernel"] as? String ?? "" }
            out.append(e)
            let plugins = url.appendingPathComponent("Contents/PlugIns")
            for p in ((try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)) ?? [])
                .filter({ $0.pathExtension == "kext" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                add(p, "\(rel)/Contents/PlugIns/\(p.lastPathComponent)")
            }
        }
        add(bundle, relative)
        return out
    }
}

enum Report {
    static func make(h: HardwareProfile, plan: BuildPlan, notes: [String], installed: [(String, String)], kexts: [KextEntry],
                     ssdts: [String], drivers: [String], oc: String, config: NSDictionary, current: CurrentEFI?,
                     validate: String, validated: Bool) -> String {
        var r = "Сборка EFI — NullMoth Updater\n\(Date())\n\n"
        r += "ЖЕЛЕЗО\n"
        r += "  CPU: \(h.cpuBrand) (\(h.cpuName)); macOS видит \(h.coresSeen) ядер / \(h.threadsSeen) потоков\(h.cpuidSpoofActive ? ", подмена CPUID активна" : "")\n"
        r += "  Тип: \(h.isLaptop ? "ноутбук" : "настольный"), память \(h.memoryGB) ГБ, сейчас SMBIOS \(h.smbiosModel)\n"
        r += "  Графика: \(h.nvidia.map { "NVIDIA \($0.id)" } ?? "-")\(h.igpu.map { ", Intel iGPU \($0.id)" } ?? ", встроенная отключена")\n"
        r += "  Сеть: \(h.ethernet.map(\.id).joined(separator: ", ")); Wi-Fi \(h.wifi?.id ?? "-"); NVMe: \(h.hasNVMe ? "да" : "нет")\n"
        r += "  Звук: \(h.codecName), layout \(h.alcLayout.map(String.init) ?? "?")\n"
        r += "  ACPI: \\_SB.\(h.acpiRoot).\(h.lpcName); EC: \(h.hasECDevice ? (h.ecIsDummy ? "фальшивый из SSDT" : "настоящий") : "нет"); CPU \(h.cpuPath)\(h.cpuIsDevice ? " (Device)" : ""); тачпад \(h.i2cTouchpad.isEmpty ? "-" : h.i2cTouchpad)\n\n"
        r += "OpenCore \(oc)\n\nКЕКСТЫ (в порядке загрузки)\n"
        for k in kexts { r += "  \(k.enabled ? "+" : "-") \(k.bundlePath)\n" }
        r += "\nПочему эти кексты:\n"; for (b, why) in installed { r += "  \(b): \(why)\n" }
        r += "\nSSDT: \(ssdts.joined(separator: ", "))\nДрайверы UEFI: \(drivers.joined(separator: ", "))\n"
        let bootArgs = ((config["NVRAM"] as? NSDictionary)?["Add"] as? NSDictionary)?[ConfigBuilder.bootGUID] as? NSDictionary
        r += "boot-args: \(bootArgs?["boot-args"] as? String ?? "")\n\n"
        if !plan.warnings.isEmpty { r += "ВНИМАНИЕ\n"; for w in plan.warnings { r += "  ! \(w)\n" }; r += "\n" }
        if !notes.isEmpty { r += "ЗАМЕТКИ\n"; for n in notes { r += "  · \(n)\n" }; r += "\n" }
        if let cur = current { r += diff(new: config, current: cur, kexts: kexts, ssdts: ssdts, drivers: drivers) }
        r += "\nocvalidate: \(validated ? "замечаний нет" : "ЕСТЬ ЗАМЕЧАНИЯ")\n\(validate)\n"
        r += """

        КАК ПРОВЕРИТЬ БЕЗ РИСКА
          1. Отформатируй флешку в FAT32 (схема GUID) и скопируй на неё папку EFI из этой сборки
             (вкладка «EFI» → «Перенести EFI», источник — эта папка, или вручную в корень флешки).
          2. Перезагрузись и выбери флешку в загрузочном меню BIOS (F12/F11/Esc).
          3. Если macOS загрузилась и всё работает — переноси EFI с флешки на SSD во вкладке «EFI».
             Если нет — просто выдерни флешку: SSD грузится со старой EFI, она не тронута.

        """
        return r
    }

    private static func diff(new: NSDictionary, current: CurrentEFI, kexts: [KextEntry], ssdts: [String], drivers: [String]) -> String {
        var r = "ОТЛИЧИЯ ОТ ТЕКУЩЕЙ EFI\n"
        let curKexts = Set(((current.value("Kernel/Add") as? [[String: Any]]) ?? []).filter { $0["Enabled"] as? Bool == true }.compactMap { $0["BundlePath"] as? String })
        let newKexts = Set(kexts.filter(\.enabled).map(\.bundlePath))
        let addK = newKexts.subtracting(curKexts).sorted(), remK = curKexts.subtracting(newKexts).sorted()
        if !addK.isEmpty { r += "  кексты добавлены: \(addK.joined(separator: ", "))\n" }
        if !remK.isEmpty { r += "  кексты убраны: \(remK.joined(separator: ", "))\n" }
        let curSSDT = Set(((current.value("ACPI/Add") as? [[String: Any]]) ?? []).filter { $0["Enabled"] as? Bool == true }.compactMap { $0["Path"] as? String })
        let addS = Set(ssdts).subtracting(curSSDT).sorted(), remS = curSSDT.subtracting(ssdts).sorted()
        if !addS.isEmpty { r += "  SSDT добавлены: \(addS.joined(separator: ", "))\n" }
        if !remS.isEmpty { r += "  SSDT убраны: \(remS.joined(separator: ", "))\n" }
        let curDrv = Set(((current.value("UEFI/Drivers") as? [[String: Any]]) ?? []).filter { $0["Enabled"] as? Bool == true }.compactMap { $0["Path"] as? String })
        if curDrv != Set(drivers) { r += "  драйверы UEFI: было \(curDrv.sorted().joined(separator: ", ")); стало \(drivers.joined(separator: ", "))\n" }
        for sect in ["Booter/Quirks", "Kernel/Quirks", "UEFI/Quirks", "Misc/Boot", "Misc/Security", "Kernel/Emulate"] {
            let nd = sect.split(separator: "/").reduce(new as Any?) { ($0 as? NSDictionary)?[String($1)] } as? NSDictionary ?? [:]
            let cd = current.value(sect) as? [String: Any] ?? [:]
            for k in (nd.allKeys as? [String] ?? []).sorted() {
                let a = nd[k], b = cd[k]
                if let a = a as? NSObject, let b = b as? NSObject, a.isEqual(b) { continue }
                if b == nil { continue }
                r += "  \(sect)/\(k): было \(fmt(b)), стало \(fmt(a))\n"
            }
        }
        let na = ((new["NVRAM"] as? NSDictionary)?["Add"] as? NSDictionary)?[ConfigBuilder.bootGUID] as? NSDictionary
        let oldArgs = current.value("NVRAM/Add/\(ConfigBuilder.bootGUID)/boot-args") as? String ?? ""
        if (na?["boot-args"] as? String ?? "") != oldArgs { r += "  boot-args: было «\(oldArgs)»\n" }
        if r == "ОТЛИЧИЯ ОТ ТЕКУЩЕЙ EFI\n" { r += "  существенных отличий нет\n" }
        return r + "\n"
    }

    private static func fmt(_ v: Any?) -> String {
        switch v {
        case let d as Data: return "<" + d.map { String(format: "%02X", $0) }.joined() + ">"
        case let b as Bool: return b ? "true" : "false"
        case nil: return "—"
        default: return "\(v!)"
        }
    }
}
