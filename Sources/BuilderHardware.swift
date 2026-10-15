import Foundation

/// A PCI function as macOS sees it.
struct PCIDev {
    let vendor: UInt32, device: UInt32, cls: UInt32, subVendor: UInt32, subDevice: UInt32
    let name: String, location: String, acpiPath: String
    var classBase: UInt32 { cls >> 8 }        // 0x0300 VGA, 0x0200 Ethernet, 0x0280 Wi-Fi, 0x0403 HDA, 0x0108 NVMe
    var id: String { String(format: "%04x:%04x", vendor, device) }
}

/// Everything the EFI builder decides from. Read from the running macOS, so it describes the machine as it boots now.
struct HardwareProfile {
    var cpuBrand = ""
    var intelGen = 0                 // 12 for "12th Gen Intel", 0 when unknown or not Intel
    var cpuModelSeen = 0             // machdep.cpu.model: 165 (Comet Lake) on an Alder Lake means a CPUID spoof is active
    var coresSeen = 0, threadsSeen = 0
    var isAMD = false
    var isLaptop = false
    var memoryGB = 0
    var smbiosModel = ""
    var pci: [PCIDev] = []
    var igpu: PCIDev?
    var nvidia: PCIDev?
    var amdGPU: PCIDev?
    var ethernet: [PCIDev] = []
    var wifi: PCIDev?
    var hasNVMe = false
    var hdaCodec: UInt32 = 0         // 0x10EC0256 for Realtek ALC256
    var alcLayout: Int?              // what AppleALC runs with now
    // ACPI
    var acpiRoot = ""                // PC00 or PCI0
    var lpcName = ""                 // LPCB, LPC0 …
    var ecName = ""                  // name of the real PNP0C09 controller macOS can see (EC, EC0, H_EC …), "" if hidden
    var hasECDevice = false          // a device named EC under LPC that macOS uses (a real one, or the dummy ACID0001)
    var ecIsDummy = false            // that EC is the dummy from an SSDT (_HID ACID0001): the current EFI carries SSDT-EC
    var hasAWAC = false
    var hasALS = false
    var hasSBUS = false, hasMCHC = false
    var i2cTouchpad = ""             // e.g. I2C0.TPD0
    var hasPS2Keyboard = false
    var asusATK = false
    var cpuPath = ""                 // \_SB.PR00 …
    var cpuIsDevice = false          // CPUs declared as Device (ACPI0007), as on Alder Lake: SSDT-PLUG-ALT, not SSDT-PLUG

    var cpuName: String {
        switch intelGen {
        case 10: return "Comet Lake (10th)"
        case 11: return "Rocket/Tiger Lake (11th)"
        case 12: return "Alder Lake (12th)"
        case 13, 14: return "Raptor Lake (\(intelGen)th)"
        default: return isAMD ? "AMD" : "Intel"
        }
    }
    /// Alder Lake and newer are not known to macOS: they boot with ProvideCurrentCpuInfo and a Comet Lake CPUID.
    var hybridIntel: Bool { intelGen >= 12 }
    var cpuidSpoofActive: Bool { hybridIntel && cpuModelSeen == 165 }
    var codecName: String {
        let known: [UInt32: String] = [0x10EC0256: "Realtek ALC256", 0x10EC0255: "Realtek ALC255", 0x10EC0257: "Realtek ALC257",
                                       0x10EC0236: "Realtek ALC236", 0x10EC0295: "Realtek ALC295", 0x10EC0897: "Realtek ALC897",
                                       0x10EC1220: "Realtek ALC1220", 0x10EC0285: "Realtek ALC285", 0x10EC0289: "Realtek ALC289",
                                       0x10EC0287: "Realtek ALC287", 0x10EC0245: "Realtek ALC245", 0x10EC0294: "Realtek ALC294"]
        if hdaCodec == 0 { return "не определён" }
        return known[hdaCodec] ?? String(format: "0x%08X", hdaCodec)
    }
}

enum HardwareDetector {
    private static func sysctl(_ k: String) -> String {
        Shell.run("/usr/sbin/sysctl", ["-n", k], stderr: false).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func ioregPlist(_ args: [String]) -> Any? {
        let r = Shell.run("/usr/sbin/ioreg", ["-a"] + args, timeout: 60, stderr: false)
        guard let d = r.output.data(using: .utf8) else { return nil }
        return try? PropertyListSerialization.propertyList(from: d, format: nil)
    }

    private static func u32(_ v: Any?) -> UInt32 {
        if let d = v as? Data, d.count >= 2 {
            var x: UInt32 = 0
            for (i, b) in d.prefix(4).enumerated() { x |= UInt32(b) << (8 * UInt32(i)) }
            return x
        }
        if let n = v as? NSNumber { return n.uint32Value }
        return 0
    }

    private static func str(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let d = v as? Data { return String(decoding: d, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0")) }
        return ""
    }

    static func detect() -> HardwareProfile {
        var h = HardwareProfile()
        h.cpuBrand = sysctl("machdep.cpu.brand_string")
        h.cpuModelSeen = Int(sysctl("machdep.cpu.model")) ?? 0
        h.coresSeen = Int(sysctl("machdep.cpu.core_count")) ?? 0
        h.threadsSeen = Int(sysctl("machdep.cpu.thread_count")) ?? 0
        h.memoryGB = Int((Int64(sysctl("hw.memsize")) ?? 0) >> 30)
        h.smbiosModel = sysctl("hw.model")
        h.isAMD = h.cpuBrand.uppercased().contains("AMD")
        if let r = h.cpuBrand.range(of: #"(\d+)th Gen Intel"#, options: .regularExpression) {
            h.intelGen = Int(h.cpuBrand[r].prefix { $0.isNumber }) ?? 0
        } else if h.cpuBrand.contains("Intel"), let r = h.cpuBrand.range(of: #"i[3579]-(\d{4,5})"#, options: .regularExpression) {
            let digits = h.cpuBrand[r].dropFirst(3)
            h.intelGen = Int(digits.count == 5 ? digits.prefix(2) : digits.prefix(1)) ?? 0
        }

        // battery: a laptop
        if let ps = ioregPlist(["-r", "-c", "AppleSmartBattery", "-d", "1"]) as? [[String: Any]], !ps.isEmpty { h.isLaptop = true }
        if !h.isLaptop {
            let batt = Shell.run("/usr/bin/pmset", ["-g", "batt"], stderr: false).output
            h.isLaptop = batt.contains("InternalBattery")
        }

        // PCI
        if let devs = ioregPlist(["-r", "-c", "IOPCIDevice", "-d", "1", "-l"]) as? [[String: Any]] {
            for d in devs {
                let dev = PCIDev(vendor: u32(d["vendor-id"]), device: u32(d["device-id"]), cls: u32(d["class-code"]),
                                 subVendor: u32(d["subsystem-vendor-id"]), subDevice: u32(d["subsystem-id"]),
                                 name: str(d["IORegistryEntryName"]), location: str(d["pcidebug"]), acpiPath: str(d["acpi-path"]))
                h.pci.append(dev)
                switch (dev.vendor, dev.classBase) {
                case (0x8086, 0x0300), (0x8086, 0x0380): if dev.location.hasPrefix("0:2:0") { h.igpu = dev }
                case (0x10DE, 0x0300), (0x10DE, 0x0302): h.nvidia = dev
                case (0x1002, 0x0300), (0x1002, 0x0380): h.amdGPU = dev
                case (_, 0x0200): h.ethernet.append(dev)
                case (_, 0x0280): h.wifi = dev
                case (_, 0x0108): h.hasNVMe = true
                default: break
                }
            }
        }

        // audio codec and the layout AppleALC uses now
        if let codecs = ioregPlist(["-r", "-c", "IOHDACodecDevice", "-d", "1", "-l"]) as? [[String: Any]] {
            for c in codecs {
                let v = (c["IOHDACodecVendorID"] as? NSNumber)?.uint32Value ?? 0
                if v >> 16 != 0x8086, v != 0 { h.hdaCodec = v; break }   // the Intel HDMI codec is not the one we want
            }
        }
        if let hdef = ioregPlist(["-r", "-n", "HDEF", "-d", "1", "-l"]) as? [[String: Any]], let d = hdef.first {
            let alc = u32(d["alc-layout-id"]), lay = u32(d["layout-id"])
            if alc != 0 { h.alcLayout = Int(alc) } else if lay != 0 && lay != 7 { h.alcLayout = Int(lay) }
        }

        detectACPI(&h)
        return h
    }

    /// Walks the ACPI device tree (IOACPIPlane) for the names the SSDTs need.
    private static func detectACPI(_ h: inout HardwareProfile) {
        guard let root = ioregPlist(["-p", "IOACPIPlane", "-l"]) as? [String: Any] else { return }
        func walk(_ n: [String: Any], _ path: [String]) {
            let name = str(n["IORegistryEntryName"]).components(separatedBy: "@").first ?? ""
            let p = path + [name]
            // in this plane the _HID sits in "name"; compatible carries the _CID
            let hid = str(n["name"]) + " " + str(n["_HID"]) + " " + str(n["compatible"])
            let parent = path.last ?? ""
            if parent == "_SB", ["PC00", "PCI0", "PC01"].contains(name), h.acpiRoot.isEmpty { h.acpiRoot = name }
            if h.lpcName.isEmpty, parent == h.acpiRoot, !parent.isEmpty, str(n["IORegistryEntryLocation"]) == "1f0000" { h.lpcName = name }
            if hid.contains("PNP0C09") { h.ecName = name }
            if name == "EC", parent == h.lpcName, !parent.isEmpty {
                h.hasECDevice = true
                h.ecIsDummy = hid.contains("ACID0001")
            }
            if hid.contains("ACPI000E") || name == "AWAC" { h.hasAWAC = true }
            if hid.contains("ACPI0008") { h.hasALS = true }
            if name == "SBUS" { h.hasSBUS = true }
            if name == "MCHC" { h.hasMCHC = true }
            if hid.contains("PNP0C50") && parent.hasPrefix("I2C") { h.i2cTouchpad = "\(parent).\(name)" }
            if hid.contains("PNP0303") || hid.contains("PNP030B") || name == "PS2K" { h.hasPS2Keyboard = true }
            if name == "ATKD" { h.asusATK = true }
            if h.cpuPath.isEmpty, ["_SB", "_PR"].contains(parent), ["PR00", "CP00", "CPU0", "C000", "P000"].contains(name) {
                h.cpuPath = "\\\(parent).\(name)"
                h.cpuIsDevice = hid.contains("ACPI0007")
            }
            for c in n["IORegistryEntryChildren"] as? [[String: Any]] ?? [] { walk(c, p) }
        }
        walk(root, [])
    }
}
