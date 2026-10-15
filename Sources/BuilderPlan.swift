import Foundation

/// The EFI this Mac boots from now, read so a new build keeps what is specific to this machine.
struct CurrentEFI {
    let root: URL                    // the mounted partition
    var config: [String: Any] = [:]
    var kexts: Set<String> = []      // top-level bundle names in EFI/OC/Kexts
    var drivers: Set<String> = []
    var tools: Set<String> = []
    var acpi: Set<String> = []
    var oc: URL { root.appendingPathComponent("EFI/OC") }

    static func read(_ mount: String) -> CurrentEFI? {
        var c = CurrentEFI(root: URL(fileURLWithPath: mount))
        let fm = FileManager.default
        guard let data = fm.contents(atPath: c.oc.appendingPathComponent("config.plist").path),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        c.config = plist
        func names(_ sub: String, _ ext: String) -> Set<String> {
            Set(((try? fm.contentsOfDirectory(atPath: c.oc.appendingPathComponent(sub).path)) ?? []).filter { $0.lowercased().hasSuffix(ext) })
        }
        c.kexts = names("Kexts", ".kext"); c.drivers = names("Drivers", ".efi"); c.tools = names("Tools", ".efi"); c.acpi = names("ACPI", ".aml")
        return c
    }

    func value(_ path: String) -> Any? {
        var cur: Any? = config
        for k in path.split(separator: "/") { cur = (cur as? [String: Any])?[String(k)] }
        return cur
    }
}

/// Where a kext comes from.
enum KextSource {
    case buildRepo(String)                       // dortania/build-repo entry name (checked against its SHA-256)
    case github(repo: String, asset: String)     // latest release, asset name matching this regex
    case url(String, sha256: String)             // a pinned download
    case current                                 // copied from the EFI this Mac boots now
}

struct KextPick {
    let bundles: [String]        // top-level .kext bundles to install from the source
    let source: KextSource
    let reason: String
    var dropPlugins: [String] = []   // nested plug-ins to leave disabled (VoodooPS2's VoodooInput when VoodooI2C brings its own)
}

struct BuildPlan {
    var kexts: [KextPick] = []
    var ssdts: [(file: String, reason: String)] = []
    var drivers = ["OpenRuntime.efi", "OpenHfsPlus.efi", "ResetNvramEntry.efi"]
    var bootArgs: [String] = []
    var warnings: [String] = []
    var notes: [String] = []
    var smbiosModel = ""
    var layout: Int?
}

enum Planner {
    /// The NullMoth driver's own boot arguments (its README) plus what this machine needs.
    static let nullmothArgs = ["nvfb=1", "nvaccel=1", "nvfbheads=4", "-nvkmsnosmooth", "amfi_get_out_of_my_way=0x1", "amfi=0x80",
                               "ipc_control_port_options=0"]

    static func plan(_ h: HardwareProfile, current: CurrentEFI?) -> BuildPlan {
        var p = BuildPlan()
        let hasCurrent = current != nil
        func have(_ k: String) -> Bool { current?.kexts.contains(k) ?? false }

        if h.isAMD { p.warnings.append("Процессор AMD: правила этого сборщика написаны для Intel. Нужны патчи ядра AMD Vanilla — собирай EFI по Dortania вручную.") }
        if h.intelGen >= 15 || h.cpuBrand.contains("Ultra") { p.warnings.append("Core Ultra / 15-е поколение macOS не поддерживает даже с подменой CPUID.") }

        // --- kexts (Dortania: Gathering files; NullMoth README for RestrictEvents and AMFIPass) ---
        p.kexts.append(KextPick(bundles: ["Lilu.kext"], source: .buildRepo("Lilu"), reason: "основа для всех плагинов"))
        var smc = ["VirtualSMC.kext", "SMCProcessor.kext"]
        if h.isLaptop { smc.append("SMCBatteryManager.kext") } else { smc.append("SMCSuperIO.kext") }
        p.kexts.append(KextPick(bundles: smc, source: .buildRepo("VirtualSMC"), reason: h.isLaptop ? "эмуляция SMC, температура CPU, батарея" : "эмуляция SMC, датчики"))
        p.kexts.append(KextPick(bundles: ["WhateverGreen.kext"], source: .buildRepo("WhateverGreen"), reason: "исправления графики и вывода изображения"))
        if h.pci.contains(where: { $0.classBase == 0x0403 && $0.vendor == 0x8086 }) {
            p.kexts.append(KextPick(bundles: ["AppleALC.kext"], source: .buildRepo("AppleALC"), reason: "звук \(h.codecName)"))
        }
        if h.nvidia != nil {
            p.kexts.append(KextPick(bundles: ["RestrictEvents.kext"], source: .buildRepo("RestrictEvents"), reason: "нужен драйверу NullMoth"))
            p.kexts.append(KextPick(bundles: ["AMFIPass.kext"],
                                    source: .url("https://github.com/dortania/OpenCore-Legacy-Patcher/raw/main/payloads/Kexts/Acidanthera/AMFIPass-v1.4.1-RELEASE.zip",
                                                 sha256: "07b266145906db41f4b13a7938fbb173ea28888cc1fa65f84417f8820adc961e"),
                                    reason: "даёт WindowServer загрузить драйвер NullMoth (как в 1401)"))
        }
        if h.hasNVMe { p.kexts.append(KextPick(bundles: ["NVMeFix.kext"], source: .buildRepo("NVMeFix"), reason: "энергосбережение NVMe")) }
        if h.hybridIntel { p.kexts.append(KextPick(bundles: ["CpuTscSync.kext"], source: .buildRepo("CpuTscSync"), reason: "синхронизация TSC на гибридных CPU")) }
        if h.isLaptop { p.kexts.append(KextPick(bundles: ["BrightnessKeys.kext"], source: .buildRepo("BrightnessKeys"), reason: "клавиши яркости")) }

        let i2c = !h.i2cTouchpad.isEmpty
        if h.hasPS2Keyboard {
            p.kexts.append(KextPick(bundles: ["VoodooPS2Controller.kext"], source: .buildRepo("VoodooPS2"),
                                    reason: "клавиатура PS/2" + (h.isLaptop ? " ноутбука" : ""),
                                    dropPlugins: i2c ? ["VoodooInput.kext"] : []))
        }
        if i2c {
            p.kexts.append(KextPick(bundles: ["VoodooI2C.kext", "VoodooI2CHID.kext"], source: .buildRepo("VoodooI2C"),
                                    reason: "тачпад I2C (\(h.i2cTouchpad))"))
        }

        for e in h.ethernet {
            switch (e.vendor, e.device) {
            case (0x10EC, 0x8168), (0x10EC, 0x8111), (0x10EC, 0x8169):
                p.kexts.append(KextPick(bundles: ["RealtekRTL8111.kext"], source: .buildRepo("RealtekRTL8111"), reason: "Ethernet Realtek \(e.id)"))
            case (0x10EC, 0x8125):
                p.kexts.append(KextPick(bundles: ["LucyRTL8125Ethernet.kext"], source: .github(repo: "Mieze/LucyRTL8125Ethernet", asset: #"LucyRTL8125Ethernet.*\.zip"#), reason: "Ethernet Realtek 2.5G"))
            case (0x8086, 0x15F2), (0x8086, 0x15F3), (0x8086, 0x125B), (0x8086, 0x125C):
                p.notes.append("Ethernet Intel I225/I226 (\(e.id)) работает встроенным драйвером Apple, кекст не нужен.")
            case (0x8086, _):
                p.kexts.append(KextPick(bundles: ["IntelMausi.kext"], source: .buildRepo("IntelMausi"), reason: "Ethernet Intel \(e.id)"))
            default:
                p.warnings.append("Ethernet \(e.id) не распознан — драйвер подбери вручную.")
            }
        }

        if let w = h.wifi {
            if w.vendor == 0x8086 {
                if have("AirportItlwm.kext") {
                    p.kexts.append(KextPick(bundles: ["AirportItlwm.kext"], source: .current, reason: "Wi-Fi Intel: сборка под Sequoia из текущей EFI (на GitHub последняя — под Sonoma 14.4)"))
                } else {
                    p.kexts.append(KextPick(bundles: ["itlwm.kext"], source: .github(repo: "OpenIntelWireless/itlwm", asset: #"^itlwm_v.*_stable\.kext\.zip$"#),
                                            reason: "Wi-Fi Intel (itlwm, подключение через приложение HeliPort)"))
                    p.warnings.append("AirportItlwm под Sequoia официально не выпущен — взят itlwm, Wi-Fi включается через HeliPort.")
                }
                p.kexts.append(KextPick(bundles: ["IntelBluetoothFirmware.kext", "IntelBTPatcher.kext"], source: .buildRepo("IntelBluetoothFirmware"), reason: "Bluetooth Intel"))
                p.kexts.append(KextPick(bundles: ["BlueToolFixup.kext"], source: .buildRepo("BrcmPatchRAM"), reason: "Bluetooth в macOS 12+"))
            } else {
                p.warnings.append(String(format: "Wi-Fi %04x:%04x — не Intel; подбери кекст вручную (Broadcom: AirportBrcmFixup).", w.vendor, w.device))
            }
        }

        // machine-specific kexts nothing here can rebuild: the USB map, CPU power profile, vendor extras
        let known = Set(p.kexts.flatMap(\.bundles) + ["VoodooPS2Controller.kext", "SMCSuperIO.kext", "SMCLightSensor.kext", "itlwm.kext",
                                                       "VoodooInput.kext"])
        for k in (current?.kexts ?? []).sorted() where !known.contains(k) {
            let why: String
            switch k {
            case "UTBMap.kext": why = "карта USB этого компьютера"
            case "USBToolBox.kext": why = "загрузчик карты USB"
            case "CPUFriend.kext", "CPUFriendDataProvider.kext": why = "профиль питания CPU этого компьютера"
            case "TufRgbACPI.kext": why = "подсветка клавиатуры ASUS TUF"
            default: why = "есть в текущей EFI"
            }
            p.kexts.append(KextPick(bundles: [k], source: .current, reason: why))
        }
        if !hasCurrent || !have("UTBMap.kext") {
            p.warnings.append("Нет карты USB (UTBMap.kext). Без неё часть портов может не работать: сделай карту в приложении 1401 (USB map).")
        }

        // --- ACPI (Dortania: Getting started with ACPI) ---
        p.ssdts.append(h.cpuIsDevice ? ("SSDT-PLUG-ALT.aml", "управление питанием CPU (процессоры объявлены как Device)")
                                     : ("SSDT-PLUG.aml", "управление питанием CPU"))
        if h.isLaptop && (!h.hasECDevice || h.ecIsDummy) {
            let root = h.acpiRoot.isEmpty ? "PCI0" : h.acpiRoot, lpc = h.lpcName.isEmpty ? "LPCB" : h.lpcName
            let f = "SSDT-EC-LAPTOP-\(root)-\(lpc).aml"
            if ["PC00", "PCI0"].contains(root), ["LPCB", "LPC0"].contains(lpc) {
                p.ssdts.append((f, "устройство EC для macOS (\\_SB.\(root).\(lpc).EC)"))
            } else {
                p.warnings.append("Путь LPC \\_SB.\(root).\(lpc) нестандартный — SSDT-EC нужно сделать вручную (SSDTTime).")
            }
        }
        p.ssdts.append(("SSDT-USBX.aml", "питание USB"))
        if h.hasAWAC { p.ssdts.append(("SSDT-AWAC-DISABLE.aml", "часы AWAC → RTC")) }
        if h.hasSBUS && !h.hasMCHC, ["PC00", "PCI0"].contains(h.acpiRoot) { p.ssdts.append(("SSDT-SBUS-MCHC-\(h.acpiRoot).aml", "шина SMBus")) }
        if h.isLaptop && h.igpu != nil && h.intelGen <= 11 { p.ssdts.append(("SSDT-PNLF.aml", "подсветка экрана через встроенную графику")) }
        // SSDTs in the current EFI that this builder does not make (they may hold fixes for this exact board)
        let made = Set(p.ssdts.map(\.file))
        let replaced: Set<String> = ["SSDT-PLUG.aml", "SSDT-PLUG-ALT.aml", "SSDT-EC.aml", "SSDT-EC-USBX.aml", "SSDT-EC-USBX-LAPTOP.aml",
                                     "SSDT-EC-LAPTOP.aml", "SSDT-USBX.aml", "SSDT-AWAC.aml", "SSDT-AWAC-DISABLE.aml", "SSDT-SBUS-MCHC.aml"]
        for a in (current?.acpi ?? []).sorted() where !made.contains(a) && !replaced.contains(a) {
            p.notes.append("В текущей EFI есть \(a) — сборщик его не делает. Если он нужен, перенеси вручную (ACPI → Add).")
        }

        // --- boot-args ---
        var args = ["keepsyms=1", "debug=0x100"]
        if h.nvidia != nil { args += nullmothArgs }
        if i2c { args.append("-vi2c-force-polling") }
        if h.igpu != nil && h.intelGen >= 12 { args.append("-wegnoigpu") }
        p.bootArgs = args

        // --- audio ---
        p.layout = h.alcLayout
        if p.layout == nil && h.hdaCodec != 0 {
            p.warnings.append("Номер раскладки AppleALC не определён: звук может не заработать. Подбери alc-layout-id по списку AppleALC для \(h.codecName).")
        }

        // --- SMBIOS ---
        if let cur = current?.value("PlatformInfo/Generic/SystemProductName") as? String, !cur.isEmpty {
            p.smbiosModel = cur
        } else if h.isLaptop {
            p.smbiosModel = h.hybridIntel || h.intelGen == 10 ? "MacBookPro16,2" : "MacBookPro16,1"
        } else {
            p.smbiosModel = h.nvidia != nil ? "iMacPro1,1" : "iMac20,1"
        }
        if !hasCurrent {
            p.warnings.append("Текущая EFI не прочитана: будут новые серийные номера SMBIOS. iCloud и iMessage увидят это как новый Mac.")
        }
        return p
    }
}
