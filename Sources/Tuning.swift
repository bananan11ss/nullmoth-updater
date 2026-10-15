import Foundation

/// Driver knobs the updater can turn on for one program only, as "name:KEY=value" lines in nvrm610.conf.
struct Knob: Identifiable {
    let id: String
    let title: String
    let detail: String
    let lines: [(String, String)]
}

enum Tuning {
    static let conf = "/Library/GPUBundles/nvmtl/nvrm610.conf"
    static let pluginBinary = "/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver"
    static let begin = "# --- NullMoth Updater: per-app knobs ---"
    static let end = "# --- end NullMoth Updater ---"

    static let knobs: [Knob] = [
        Knob(id: "asynctex",
             title: "Загружать текстуры без ожидания GPU",
             detail: "NVMTL_ASYNC_TEX_UPLOAD=1. Каждое обновление текстуры (анимации воды и огня, освещение в Minecraft) больше не ждёт, пока GPU доделает весь кадр. Профиль Minecraft: ~23% кадра уходило на это ожидание; в тесте −38% времени кадра.",
             lines: [("NVMTL_ASYNC_TEX_UPLOAD", "1")]),
        Knob(id: "sharedvram",
             title: "Буферы CPU→GPU в видеопамяти",
             detail: "NVMTL_SHARED_VRAM=1. GPU читает их ~250 ГБ/с вместо ~13 ГБ/с из системной памяти (замер на этой 4070). Чтение такого буфера процессором становится медленным.",
             lines: [("NVMTL_SHARED_VRAM", "1"), ("NVMTL_SHARED_VRAM_BUDGET_MB", "1024")]),
        Knob(id: "eventwait",
             title: "Ждать GPU по событию, а не опросом",
             detail: "NVRM_EVENT_WAIT=1. Меньше нагрузки на CPU (по docs/EVENT-WAIT.md −37…53%), ноутбук меньше греется; задержка короткой работы чуть выше.",
             lines: [("NVRM_EVENT_WAIT", "1")]),
        Knob(id: "zerofill",
             title: "Не обнулять новые буферы на GPU",
             detail: "NVMTL_ZERO_FILL=host. Быстрее создание буферов; память всё ещё обнуляется на стороне CPU.",
             lines: [("NVMTL_ZERO_FILL", "host")]),
    ]

    /// Only the plugin built from fixed-2.0.0 reads "name:KEY=value" lines; older ones skip them harmlessly.
    static func pluginSupportsPerApp() -> Bool {
        guard let data = FileManager.default.contents(atPath: pluginBinary) else { return false }
        return data.range(of: Data("knob(s) for %s only".utf8)) != nil
    }

    static func readConf() -> String { (try? String(contentsOfFile: conf, encoding: .utf8)) ?? "" }

    /// Knob ids turned on for `process` in the managed block.
    static func enabled(in text: String, process: String) -> Set<String> {
        var have: [String: String] = [:]
        var inside = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == begin { inside = true; continue }
            if line == end { inside = false; continue }
            guard inside, line.hasPrefix(process + ":"), let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.index(line.startIndex, offsetBy: process.count + 1)..<eq])
            have[key] = String(line[line.index(after: eq)...])
        }
        return Set(knobs.filter { k in k.lines.allSatisfy { have[$0.0] == $0.1 } }.map(\.id))
    }

    /// The conf text with the managed block replaced by `on` for `process`. Lines for other programs are kept.
    static func render(_ text: String, process: String, on: Set<String>) -> String {
        var outside: [String] = []
        var keptOthers: [String] = []
        var inside = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == begin { inside = true; continue }
            if t == end { inside = false; continue }
            if inside {
                if !t.hasPrefix(process + ":") && !t.isEmpty { keptOthers.append(line) }
            } else {
                outside.append(line)
            }
        }
        while outside.last?.isEmpty == true { outside.removeLast() }
        var block: [String] = keptOthers
        for k in knobs where on.contains(k.id) {
            for (key, val) in k.lines { block.append("\(process):\(key)=\(val)") }
        }
        var out = outside.joined(separator: "\n") + "\n"
        if !block.isEmpty { out += begin + "\n" + block.joined(separator: "\n") + "\n" + end + "\n" }
        return out
    }

    static func validProcessName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 64 && s.range(of: #"^[A-Za-z0-9._ -]+$"#, options: .regularExpression) != nil
    }
}
