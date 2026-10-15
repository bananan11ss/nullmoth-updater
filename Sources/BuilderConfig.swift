import Foundation

/// One Kernel → Add entry, with what is needed to order it.
struct KextEntry {
    let bundlePath: String           // relative to EFI/OC/Kexts, e.g. "VoodooI2C.kext/Contents/PlugIns/VoodooGPIO.kext"
    let identifier: String
    let deps: [String]
    let executable: String           // "Contents/MacOS/Lilu" or "" for codeless
    var enabled: Bool
    var minKernel = "", maxKernel = ""
    let comment: String

    static func read(_ bundle: URL, relative: String, comment: String, enabled: Bool) -> KextEntry? {
        let plistURL = bundle.appendingPathComponent("Contents/Info.plist")
        guard let d = FileManager.default.contents(atPath: plistURL.path),
              let p = (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any] else { return nil }
        let exe = p["CFBundleExecutable"] as? String ?? ""
        let hasExe = !exe.isEmpty && FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/MacOS/\(exe)").path)
        return KextEntry(bundlePath: relative, identifier: p["CFBundleIdentifier"] as? String ?? relative,
                         deps: Array((p["OSBundleLibraries"] as? [String: Any] ?? [:]).keys),
                         executable: hasExe ? "Contents/MacOS/\(exe)" : "", enabled: enabled, comment: comment)
    }

    var dict: [String: Any] {
        ["Arch": "x86_64", "BundlePath": bundlePath, "Comment": comment, "Enabled": enabled, "ExecutablePath": executable,
         "MaxKernel": maxKernel, "MinKernel": minKernel, "PlistPath": "Contents/Info.plist"]
    }

    /// Every kext after the ones it links against (Lilu first, VirtualSMC before its plug-ins, a plug-in after its parent).
    static func ordered(_ list: [KextEntry]) -> [KextEntry] {
        let ids = Set(list.map(\.identifier))
        var out: [KextEntry] = [], placedIDs = Set<String>(), placedPaths = Set<String>(), left = list
        while !left.isEmpty {
            guard let i = left.firstIndex(where: { k in
                let parts = k.bundlePath.components(separatedBy: "/Contents/PlugIns/")
                let parent = parts.dropLast().joined(separator: "/Contents/PlugIns/")
                let parentOK = parent.isEmpty || placedPaths.contains(parent) || !left.contains { $0.bundlePath == parent }
                return parentOK && k.deps.allSatisfy { !ids.contains($0) || placedIDs.contains($0) || $0 == k.identifier }
            }) else { out += left; break }   // a dependency cycle: keep the rest in the order given
            let k = left.remove(at: i)
            out.append(k); placedIDs.insert(k.identifier); placedPaths.insert(k.bundlePath)
        }
        return out
    }
}

enum ConfigBuilder {
    static let bootGUID = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
    static let ocGUID = "4D1FDA02-38C7-4A6A-9CC6-4BCCA8B30102"

    static func hex(_ s: String) -> Data {
        var d = Data(); var it = s.replacingOccurrences(of: " ", with: "").makeIterator()
        while let a = it.next(), let b = it.next() { d.append(UInt8(String([a, b]), radix: 16) ?? 0) }
        return d
    }

    private static func set(_ d: NSMutableDictionary, _ path: String, _ v: Any) {
        let parts = path.split(separator: "/").map(String.init)
        var cur = d
        for k in parts.dropLast() {
            if let n = cur[k] as? NSMutableDictionary { cur = n } else { let n = NSMutableDictionary(); cur[k] = n; cur = n }
        }
        cur[parts.last!] = v
    }

    /// An array entry with every key the sample's own first entry has (so a key a new OpenCore adds, such as
    /// UEFI/Drivers HideVerbose in 1.0.9, is never missing), with `values` on top.
    private static func entries(_ sample: NSDictionary, _ path: String, _ values: [[String: Any]]) -> NSMutableArray {
        let template = ((get(sample, path) as? NSArray)?.firstObject as? NSDictionary) ?? [:]
        return NSMutableArray(array: values.map { v -> NSDictionary in
            let e = NSMutableDictionary(dictionary: template)
            for (k, x) in v { e[k] = x }
            return e
        })
    }

    private static func get(_ d: NSDictionary, _ path: String) -> Any? {
        var cur: Any? = d
        for k in path.split(separator: "/") { cur = (cur as? NSDictionary)?[String(k)] }
        return cur
    }

    /// config.plist from OpenCore's own Sample.plist (so every key matches this OpenCore version), with the values
    /// Dortania gives for this CPU family, the NullMoth driver's settings, and this machine's own values from the
    /// current EFI where one was read.
    static func make(sample: URL, h: HardwareProfile, plan: BuildPlan, kexts: [KextEntry], ssdts: [String], drivers: [String],
                     tools: [[String: Any]], current: CurrentEFI?, macserial: URL?, notes: inout [String]) throws -> NSMutableDictionary {
        guard let data = FileManager.default.contents(atPath: sample.path),
              let c = try PropertyListSerialization.propertyList(from: data, options: .mutableContainersAndLeaves, format: nil) as? NSMutableDictionary
        else { throw FetchError.missing("Sample.plist не прочитан") }
        let cur = current.map { NSDictionary(dictionary: $0.config) }
        // a separate, untouched parse of the sample: the entry templates must not see the edits below
        let sampleCopy = ((try? PropertyListSerialization.propertyList(from: data, format: nil)) as? NSDictionary) ?? [:]
        func carry(_ path: String) -> Any? { cur.flatMap { get($0, path) } }

        // ACPI
        set(c, "ACPI/Add", entries(sampleCopy, "ACPI/Add", ssdts.map { ["Comment": $0, "Enabled": true, "Path": $0] }))
        set(c, "ACPI/Delete", NSMutableArray()); set(c, "ACPI/Patch", NSMutableArray(array: (carry("ACPI/Patch") as? [Any]) ?? []))
        if carry("ACPI/Patch") != nil, ((carry("ACPI/Patch") as? [Any])?.isEmpty == false) { notes.append("ACPI → Patch перенесены из текущей EFI.") }

        // Booter (Dortania, Comet Lake / Alder Lake)
        set(c, "Booter/Patch", NSMutableArray())
        set(c, "Booter/MmioWhitelist", NSMutableArray(array: (carry("Booter/MmioWhitelist") as? [Any]) ?? []))
        let booter: [String: Any] = ["AvoidRuntimeDefrag": true, "DevirtualiseMmio": true, "EnableSafeModeSlide": true,
                                     "EnableWriteUnprotector": false, "ProtectUefiServices": true, "ProvideCustomSlide": true,
                                     "RebuildAppleMemoryMap": true, "SetupVirtualMap": true, "SyncRuntimePermissions": true]
        for (k, v) in booter { set(c, "Booter/Quirks/\(k)", carry("Booter/Quirks/\(k)") ?? v) }
        // NullMoth README: keep this machine's BAR settings
        set(c, "Booter/Quirks/ResizeAppleGpuBars", carry("Booter/Quirks/ResizeAppleGpuBars") ?? -1)

        // DeviceProperties: the current ones (they are this machine's), with the audio layout on top
        let dp = NSMutableDictionary(dictionary: (carry("DeviceProperties/Add") as? [String: Any]) ?? [:])
        if let l = plan.layout {
            let hdef = "PciRoot(0x0)/Pci(0x1f,0x3)"
            let props = NSMutableDictionary(dictionary: (dp[hdef] as? [String: Any]) ?? [:])
            var v = UInt32(l).littleEndian
            props["alc-layout-id"] = Data(bytes: &v, count: 4)
            dp[hdef] = props
        }
        set(c, "DeviceProperties/Add", dp)
        set(c, "DeviceProperties/Delete", NSMutableDictionary())

        // Kernel
        set(c, "Kernel/Add", entries(sampleCopy, "Kernel/Add", kexts.map(\.dict)))
        var block: [[String: Any]] = []
        if h.nvidia != nil {
            // NullMoth: keep the firmware framebuffer from taking display index 0 from NVRMFB
            block.append(["Arch": "Any", "Comment": "NullMoth: firmware framebuffer off", "Enabled": true,
                          "Identifier": "com.apple.iokit.IONDRVSupport", "MaxKernel": "", "MinKernel": "", "Strategy": "Exclude"])
        }
        set(c, "Kernel/Block", entries(sampleCopy, "Kernel/Block", block))
        set(c, "Kernel/Force", NSMutableArray())
        set(c, "Kernel/Patch", NSMutableArray(array: (carry("Kernel/Patch") as? [Any]) ?? []))
        if let kp = carry("Kernel/Patch") as? [Any], !kp.isEmpty { notes.append("Kernel → Patch (\(kp.count)) перенесены из текущей EFI.") }
        if h.hybridIntel {
            // Dortania (Alder Lake): macOS has no profile for these CPUs; boot as Comet Lake (family 6, model 0xA5)
            set(c, "Kernel/Emulate/Cpuid1Data", carry("Kernel/Emulate/Cpuid1Data") ?? hex("55060A00 00000000 00000000 00000000"))
            set(c, "Kernel/Emulate/Cpuid1Mask", carry("Kernel/Emulate/Cpuid1Mask") ?? hex("FFFFFFFF 00000000 00000000 00000000"))
        }
        let kq: [String: Any] = ["AppleCpuPmCfgLock": false, "AppleXcpmCfgLock": true, "DisableIoMapper": true,
                                 "DisableLinkeditJettison": true, "PanicNoKextDump": true, "PowerTimeoutKernelPanic": true,
                                 "ProvideCurrentCpuInfo": h.hybridIntel, "XhciPortLimit": false]
        for (k, v) in kq { set(c, "Kernel/Quirks/\(k)", carry("Kernel/Quirks/\(k)") ?? v) }

        // Misc
        let boot: [String: Any] = ["HideAuxiliary": false, "LauncherOption": "Full", "PickerMode": "Builtin", "ShowPicker": true, "Timeout": 5]
        for (k, v) in boot { set(c, "Misc/Boot/\(k)", v) }
        set(c, "Misc/Debug/AppleDebug", true); set(c, "Misc/Debug/ApplePanic", true); set(c, "Misc/Debug/DisableWatchDog", true)
        set(c, "Misc/Debug/Target", 3)
        let sec: [String: Any] = ["AllowSetDefault": true, "BlacklistAppleUpdate": true, "ExposeSensitiveData": 6, "ScanPolicy": 0,
                                  "SecureBootModel": "Disabled", "Vault": "Optional"]
        for (k, v) in sec { set(c, "Misc/Security/\(k)", v) }
        set(c, "Misc/Entries", NSMutableArray(array: (carry("Misc/Entries") as? [Any]) ?? []))
        set(c, "Misc/Tools", entries(sampleCopy, "Misc/Tools", tools))

        // NVRAM
        let addBoot = NSMutableDictionary()
        let curArgs = (carry("NVRAM/Add/\(bootGUID)/boot-args") as? String) ?? ""
        var args = plan.bootArgs
        for a in curArgs.split(separator: " ").map(String.init) where !args.contains(a) && !a.isEmpty {
            // keep this machine's own arguments, but not ones the plan replaces with a new value
            let key = a.split(separator: "=").first.map(String.init) ?? a
            if !args.contains(where: { $0.hasPrefix(key + "=") }) { args.append(a) }
        }
        addBoot["boot-args"] = args.joined(separator: " ")
        addBoot["csr-active-config"] = (carry("NVRAM/Add/\(bootGUID)/csr-active-config") as? Data) ?? hex(h.nvidia != nil ? "430A0000" : "00000000")
        addBoot["prev-lang:kbd"] = (carry("NVRAM/Add/\(bootGUID)/prev-lang:kbd") as? Data) ?? Data("ru-RU:19456".utf8)
        addBoot["run-efi-updater"] = "No"
        let nvAdd = NSMutableDictionary(dictionary: (get(c, "NVRAM/Add") as? [String: Any]) ?? [:])
        nvAdd[bootGUID] = addBoot
        set(c, "NVRAM/Add", nvAdd)
        let del = NSMutableDictionary(dictionary: (get(c, "NVRAM/Delete") as? [String: Any]) ?? [:])
        del[bootGUID] = NSMutableArray(array: ["boot-args", "csr-active-config", "prev-lang:kbd", "run-efi-updater"])
        set(c, "NVRAM/Delete", del)
        set(c, "NVRAM/WriteFlash", true)

        // PlatformInfo: this Mac's identity, or a new one from macserial
        set(c, "PlatformInfo/Automatic", true); set(c, "PlatformInfo/UpdateSMBIOSMode", "Custom")
        set(c, "PlatformInfo/UpdateDataHub", true); set(c, "PlatformInfo/UpdateNVRAM", true); set(c, "PlatformInfo/UpdateSMBIOS", true)
        let g = NSMutableDictionary(dictionary: (get(c, "PlatformInfo/Generic") as? [String: Any]) ?? [:])
        if let cg = carry("PlatformInfo/Generic") as? [String: Any], let s = cg["SystemSerialNumber"] as? String, !s.isEmpty {
            for k in ["SystemProductName", "SystemSerialNumber", "MLB", "SystemUUID", "ROM"] { if let v = cg[k] { g[k] = v } }
            notes.append("SMBIOS (\(cg["SystemProductName"] as? String ?? "?"), серийники, UUID, ROM) перенесён из текущей EFI — iCloud не заметит смены.")
        } else {
            g["SystemProductName"] = plan.smbiosModel
            if let ms = macserial {
                let r = Shell.run(ms.path, ["-m", plan.smbiosModel, "-n", "1"], stderr: false).output
                let parts = r.split(separator: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                if parts.count >= 2 { g["SystemSerialNumber"] = parts[0]; g["MLB"] = parts[1] }
            }
            g["SystemUUID"] = UUID().uuidString
            g["ROM"] = Data((0..<6).map { _ in UInt8.random(in: 0...255) })
            notes.append("SMBIOS \(plan.smbiosModel) создан заново (macserial).")
        }
        g["SpoofVendor"] = true
        set(c, "PlatformInfo/Generic", g)

        // UEFI
        set(c, "UEFI/Drivers", entries(sampleCopy, "UEFI/Drivers", drivers.map {
            ["Arguments": "", "Comment": $0, "Enabled": true, "LoadEarly": false, "Path": $0] }))
        let uq: [String: Any] = ["EnableVectorAcceleration": true, "ReleaseUsbOwnership": true, "RequestBootVarRouting": true, "UnblockFsConnect": false]
        for (k, v) in uq { set(c, "UEFI/Quirks/\(k)", carry("UEFI/Quirks/\(k)") ?? v) }
        set(c, "UEFI/Quirks/ResizeGpuBars", carry("UEFI/Quirks/ResizeGpuBars") ?? -1)
        set(c, "UEFI/ConnectDrivers", true)
        return c
    }
}
