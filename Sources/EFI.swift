import AppKit
import Foundation

/// One EFI system partition (or a FAT32 partition on a stick that holds an EFI folder).
struct ESP: Identifiable, Equatable {
    let id: String              // disk0s1
    let whole: String           // disk0
    let disk: String            // "WD PC SN560 …"
    let isInternal: Bool
    let removable: Bool
    let bus: String
    let size: Int64
    let uuid: String            // partition UUID, matched against OpenCore's boot-path
    var mountPoint: String?
    var isBoot = false

    var mounted: Bool { mountPoint != nil }
    var kind: String { isInternal && !removable ? "внутренний" : "внешний" + (bus == "USB" ? " (USB)" : "") }
    var title: String { "\(id) · \(disk.isEmpty ? "диск" : disk) · \(kind) · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))" }
}

/// What an EFI folder holds, read from a mounted partition.
struct EFIContents {
    var hasOC = false
    var hasBoot = false
    var hasConfig = false
    var others: [String] = []   // EFI/<name> folders besides OC and BOOT (Microsoft, ubuntu …): never touched
    var kexts: [String] = []
    var drivers: [String] = []
    var ocBytes: Int64 = 0
}

enum EFI {
    static let ocGUID = "4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102"

    private static func info(_ dev: String) -> [String: Any] {
        let r = Shell.run("/usr/sbin/diskutil", ["info", "-plist", dev], timeout: 30, stderr: false)
        guard let d = r.output.data(using: .utf8),
              let p = (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any] else { return [:] }
        return p
    }

    /// The partition UUID OpenCore booted from (its boot-path NVRAM variable), if OpenCore started this Mac.
    static func bootUUID() -> String? {
        // the output starts with the variable's own GUID; the partition is the one in HD(n,GPT,<uuid>,…)
        let r = Shell.run("/usr/sbin/nvram", ["\(ocGUID):boot-path"], stderr: false).output
        guard let m = r.range(of: #"GPT,[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#, options: .regularExpression)
        else { return nil }
        return String(r[m].dropFirst(4)).uppercased()
    }

    static func openCoreVersion() -> String? {
        let r = Shell.run("/usr/sbin/nvram", ["\(ocGUID):opencore-version"], stderr: false).output
        let v = r.split(separator: "\t").dropFirst().joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    /// EFI partitions on every disk, plus FAT partitions on external disks (OpenCore sticks are sometimes plain FAT32).
    static func list() -> [ESP] {
        let r = Shell.run("/usr/sbin/diskutil", ["list", "-plist"], timeout: 30, stderr: false)
        guard let d = r.output.data(using: .utf8),
              let p = (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any],
              let all = p["AllDisksAndPartitions"] as? [[String: Any]] else { return [] }
        let boot = bootUUID()
        var out: [ESP] = []
        for w in all {
            guard let whole = w["DeviceIdentifier"] as? String, let parts = w["Partitions"] as? [[String: Any]] else { continue }
            var wholeInfo: [String: Any]?
            for part in parts {
                guard let id = part["DeviceIdentifier"] as? String else { continue }
                let content = part["Content"] as? String ?? ""
                let isESP = content == "EFI" || content.uppercased() == "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
                let isFAT = content == "Microsoft Basic Data" || content == "DOS_FAT_32" || content == "Windows_FAT_32"
                if !isESP && !isFAT { continue }
                if wholeInfo == nil { wholeInfo = info(whole) }
                let wi = wholeInfo ?? [:]
                let isInt = wi["Internal"] as? Bool ?? true
                // a FAT data partition is only interesting on a stick; on an internal disk it is somebody's files
                if isFAT && isInt { continue }
                let pi = info(id)
                if isFAT, (pi["FilesystemType"] as? String) != "msdos" { continue }
                let mp = (pi["MountPoint"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let uuid = (pi["DiskUUID"] as? String ?? "").uppercased()
                out.append(ESP(id: id, whole: whole, disk: (wi["MediaName"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                               isInternal: isInt, removable: (wi["RemovableMedia"] as? Bool ?? false) || (wi["Ejectable"] as? Bool ?? false),
                               bus: wi["BusProtocol"] as? String ?? "", size: (pi["TotalSize"] as? NSNumber)?.int64Value ?? 0,
                               uuid: uuid, mountPoint: mp, isBoot: boot != nil && uuid == boot))
            }
        }
        return out
    }

    static func contents(at mount: String) -> EFIContents {
        let fm = FileManager.default
        let efi = (mount as NSString).appendingPathComponent("EFI")
        var c = EFIContents()
        let names = (try? fm.contentsOfDirectory(atPath: efi)) ?? []
        for n in names where !n.hasPrefix(".") {
            switch n.uppercased() {
            case "OC": c.hasOC = true
            case "BOOT": c.hasBoot = true
            default: c.others.append(n)
            }
        }
        let oc = (efi as NSString).appendingPathComponent("OC")
        c.hasConfig = fm.fileExists(atPath: (oc as NSString).appendingPathComponent("config.plist"))
        c.kexts = ((try? fm.contentsOfDirectory(atPath: (oc as NSString).appendingPathComponent("Kexts"))) ?? [])
            .filter { $0.hasSuffix(".kext") }.sorted()
        c.drivers = ((try? fm.contentsOfDirectory(atPath: (oc as NSString).appendingPathComponent("Drivers"))) ?? [])
            .filter { $0.lowercased().hasSuffix(".efi") }.sorted()
        let du = Shell.run("/usr/bin/du", ["-sk", oc], stderr: false).output
        c.ocBytes = (Int64(du.split(separator: "\t").first ?? "0") ?? 0) * 1024
        return c
    }

    /// The root shell script that copies EFI/OC and EFI/BOOT from one mounted partition to another. Everything the
    /// target had under OC and BOOT is saved to `backup` first; other EFI folders (Microsoft, Linux) are left alone.
    /// The copy is compared with the source and, if anything differs, the backup is put back.
    static func copyScript(src: String, dst: String, backup: String, uid: uid_t) -> String {
        let s = Shell.quote(src), d = Shell.quote(dst), b = Shell.quote(backup)
        return """
        set -u
        S=\(s); D=\(d); B=\(b)
        fail() { echo "ОШИБКА: $*"; exit 1; }
        [ -d "$S/EFI/OC" ] || fail "на источнике нет EFI/OC"
        [ -f "$S/EFI/OC/OpenCore.efi" ] || fail "на источнике нет EFI/OC/OpenCore.efi"
        [ "$(cd "$S" && pwd -P)" != "$(cd "$D" && pwd -P)" ] || fail "источник и цель совпадают"
        kb() { local t=0 x k; for x in "$@"; do [ -d "$x" ] || continue; k=$(du -sk "$x" | cut -f1); t=$((t + k)); done; echo $t; }
        need=$(kb "$S/EFI/OC" "$S/EFI/BOOT")
        old=$(kb "$D/EFI/OC" "$D/EFI/BOOT")
        free=$(df -k "$D" | awk 'NR==2{print $4}')
        [ $((free + old)) -gt $((need + 2048)) ] || fail "на цели мало места: нужно $((need/1024)) МБ, будет $(((free+old)/1024)) МБ"
        echo "== резервная копия цели -> $B"
        mkdir -p "$B" || fail "не создать папку резервной копии"
        for x in OC BOOT; do [ -d "$D/EFI/$x" ] && { ditto "$D/EFI/$x" "$B/$x" || fail "резервная копия $x"; }; done
        chown -R \(uid) "$B" 2>/dev/null
        restore() {
          echo "== возвращаю цель из резервной копии"
          local y
          for y in OC BOOT; do rm -rf "$D/EFI/$y"; [ -d "$B/$y" ] && ditto --norsrc --noextattr --noqtn "$B/$y" "$D/EFI/$y"; done
          sync
        }
        echo "== копирую"
        mkdir -p "$D/EFI" || fail "не создать EFI на цели"
        for x in OC BOOT; do
          [ -d "$S/EFI/$x" ] || continue
          rm -rf "$D/EFI/$x"
          ditto --norsrc --noextattr --noqtn "$S/EFI/$x" "$D/EFI/$x" || { restore; fail "копирование $x"; }
          echo "   EFI/$x: $(find "$D/EFI/$x" -type f | wc -l | tr -d ' ') файлов"
        done
        find "$D/EFI" -name '._*' -delete 2>/dev/null
        sync
        echo "== проверяю"
        for x in OC BOOT; do
          [ -d "$S/EFI/$x" ] || continue
          diff -rq -x '._*' -x '.DS_Store' "$S/EFI/$x" "$D/EFI/$x" || { restore; fail "копия EFI/$x не совпала с источником, цель восстановлена"; }
        done
        echo "ГОТОВО: EFI/OC$( [ -d "$S/EFI/BOOT" ] && echo " и EFI/BOOT") скопированы, проверены. Остальные папки в EFI не тронуты."
        """
    }

    static var backupRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("EFI-backups", isDirectory: true)
    }
}

@MainActor
final class EFIModel: ObservableObject {
    @Published var esps: [ESP] = []
    @Published var contents: [String: EFIContents] = [:]
    @Published var ocVersion: String?
    @Published var busy: String?
    @Published var message: String?
    @Published var failed = false
    @Published var log = ""
    @Published var source: String = ""
    @Published var target: String = ""

    func refresh() {
        busy = "Ищу EFI-разделы…"
        Task.detached {
            let list = EFI.list()
            var c: [String: EFIContents] = [:]
            for e in list { if let m = e.mountPoint { c[e.id] = EFI.contents(at: m) } }
            let v = EFI.openCoreVersion()
            let found = c
            await MainActor.run {
                let c = found
                self.esps = list; self.contents = c; self.ocVersion = v; self.busy = nil
                if !list.contains(where: { $0.id == self.source }) {
                    // default source: a stick with OpenCore, else the partition OpenCore booted from
                    self.source = list.first(where: { !$0.isInternal && c[$0.id]?.hasOC == true })?.id
                        ?? list.first(where: { $0.isBoot })?.id ?? list.first?.id ?? ""
                }
                if !list.contains(where: { $0.id == self.target }) || self.target == self.source {
                    self.target = list.first(where: { $0.isInternal && $0.id != self.source })?.id ?? ""
                }
            }
        }
    }

    private func done(_ ok: Bool, _ text: String) { busy = nil; failed = !ok; message = text }

    /// Mounts every partition in `ids` with one administrator prompt (EFI partitions only mount as root).
    private func mountAsAdmin(_ ids: [String]) async -> Bool {
        let need = ids.filter { id in esps.first(where: { $0.id == id })?.mounted == false }
        if need.isEmpty { return true }
        let cmd = need.map { "/usr/sbin/diskutil mount \($0)" }.joined(separator: " && ")
        let r = await Task.detached { Shell.runAsAdmin(cmd) }.value
        if r.status != 0 { done(false, r.status == -128 ? "Отменено" : "Не смонтировать: \(r.output)"); return false }
        return true
    }

    func mount(_ id: String) {
        busy = "Монтирую \(id)…"; message = nil
        Task {
            if await mountAsAdmin([id]) { done(true, "\(id) смонтирован"); refresh() }
        }
    }

    func unmount(_ id: String) {
        busy = "Отключаю \(id)…"; message = nil
        Task.detached {
            var r = Shell.run("/usr/sbin/diskutil", ["unmount", id])
            if r.status != 0 { r = Shell.runAsAdmin("/usr/sbin/diskutil unmount \(id)") }
            let res = r
            await MainActor.run {
                let r = res
                self.done(r.status == 0, r.status == 0 ? "\(id) отключён" : r.output)
                self.refresh()
            }
        }
    }

    func open(_ id: String) {
        guard let m = esps.first(where: { $0.id == id })?.mountPoint else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: m))
    }

    func backupNow(_ id: String) {
        busy = "Делаю резервную копию \(id)…"; message = nil
        Task {
            guard await mountAsAdmin([id]) else { return }
            let list = await Task.detached { EFI.list() }.value
            guard let m = list.first(where: { $0.id == id })?.mountPoint else { done(false, "\(id) не смонтировался"); return }
            let stamp = Self.stamp()
            let dest = EFI.backupRoot.appendingPathComponent("\(stamp)-\(id)")
            let cmd = "mkdir -p \(Shell.quote(dest.path)) && ditto \(Shell.quote(m + "/EFI")) \(Shell.quote(dest.path + "/EFI")) && chown -R \(getuid()) \(Shell.quote(EFI.backupRoot.path))"
            let r = await Task.detached { Shell.runAsAdmin(cmd) }.value
            done(r.status == 0, r.status == 0 ? "Резервная копия: \(dest.path)" : r.output)
            if r.status == 0 { NSWorkspace.shared.activateFileViewerSelecting([dest]) }
            refresh()
        }
    }

    /// Copies EFI/OC and EFI/BOOT from source to target (both mounted with one prompt), with a backup and a check.
    func copy() {
        guard let s = esps.first(where: { $0.id == source }), let t = esps.first(where: { $0.id == target }), s.id != t.id else {
            done(false, "Выбери разные источник и цель"); return
        }
        busy = "Монтирую \(s.id) и \(t.id)…"; message = nil; log = ""
        Task {
            guard await mountAsAdmin([s.id, t.id]) else { return }
            let list = await Task.detached { EFI.list() }.value
            guard let sm = list.first(where: { $0.id == s.id })?.mountPoint,
                  let tm = list.first(where: { $0.id == t.id })?.mountPoint else { done(false, "Разделы не смонтировались"); return }
            let backup = EFI.backupRoot.appendingPathComponent("\(Self.stamp())-\(t.id)-before-copy").path
            let script = EFI.copyScript(src: sm, dst: tm, backup: backup, uid: getuid())
            busy = "Копирую EFI \(s.id) → \(t.id)…"
            let r = await Task.detached { Shell.runAsAdmin(script) }.value
            log = r.output
            done(r.status == 0, r.status == 0
                 ? "Готово. Старая EFI цели сохранена в \(backup). Чтобы грузиться с \(t.id), выбери его в загрузочном меню BIOS (F12/F11/Esc)."
                 : (r.status == -128 ? "Отменено" : "Не получилось, подробности ниже. Цель не изменена или восстановлена из копии."))
            refresh()
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"; return f.string(from: Date())
    }
}
