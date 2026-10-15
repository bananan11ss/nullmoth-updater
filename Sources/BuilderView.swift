import AppKit
import SwiftUI

@MainActor
final class BuilderModel: ObservableObject {
    @Published var running = false
    @Published var log = ""
    @Published var report = ""
    @Published var result: URL?          // the build folder (holds EFI/ and ОТЧЁТ.txt)
    @Published var validated = false
    @Published var error: String?
    @Published var useCurrent = true

    private func say(_ s: String) { log += s + "\n" }

    /// A snapshot of the EFI OpenCore booted from, copied as root (FAT on an EFI mounts root-only) and handed to the user.
    private func snapshotBootEFI() async -> CurrentEFI? {
        let list = await Task.detached { EFI.list() }.value
        guard let boot = list.first(where: { $0.isBoot }) ?? list.first(where: { $0.isInternal }) else {
            say("   загрузочная EFI не найдена"); return nil
        }
        let snap = FileManager.default.temporaryDirectory.appendingPathComponent("efi-current-\(UUID().uuidString.prefix(8))")
        let q = Shell.quote(snap.path)
        let cmd = """
        /usr/sbin/diskutil mount \(boot.id) >/dev/null 2>&1
        mp=$(/usr/sbin/diskutil info \(boot.id) | awk -F': *' '/Mount Point/{print $2}')
        [ -n "$mp" ] && [ -d "$mp/EFI/OC" ] || { echo "на \(boot.id) нет EFI/OC"; exit 3; }
        mkdir -p \(q) && ditto "$mp/EFI" \(q)/EFI && chown -R \(getuid()) \(q)
        """
        say("   читаю текущую EFI с \(boot.id) (нужен пароль администратора)…")
        let r = await Task.detached { Shell.runAsAdmin(cmd) }.value
        guard r.status == 0, let cur = CurrentEFI.read(snap.path) else {
            say("   не прочитать: \(r.status == -128 ? "отменено" : r.output)"); return nil
        }
        say("   текущая EFI: \(cur.kexts.count) кекстов, \(cur.acpi.count) SSDT, SMBIOS \(cur.value("PlatformInfo/Generic/SystemProductName") as? String ?? "?")")
        return cur
    }

    func build() {
        running = true; log = ""; report = ""; result = nil; error = nil
        Task {
            var cur: CurrentEFI?
            if useCurrent {
                say("== 0. Текущая EFI")
                cur = await snapshotBootEFI()
                if cur == nil { say("   продолжаю без неё: SMBIOS будет новым") }
            }
            guard let acpi = Bundle.main.resourceURL?.appendingPathComponent("ACPI") else { error = "в приложении нет SSDT"; running = false; return }
            let b = EFIBuilder(acpiDir: acpi)
            b.log = { line in Task { @MainActor in self.say(line) } }
            do {
                let r = try await b.run(current: cur)
                report = r.report; result = r.efi.deletingLastPathComponent(); validated = r.validated
            } catch {
                self.error = error.localizedDescription
            }
            if let c = cur { try? FileManager.default.removeItem(at: c.root) }
            running = false
        }
    }
}

struct BuilderTab: View {
    @EnvironmentObject var b: BuilderModel
    @EnvironmentObject var e: EFIModel
    @State private var target = ""
    @State private var confirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Собирает EFI OpenCore с нуля под этот компьютер. Определяет железо, качает OpenCore и кексты (dortania/build-repo, проверка SHA-256), подбирает SSDT, собирает config.plist по правилам Dortania с настройками драйвера NullMoth и проверяет его через ocvalidate. Результат — папка в «Документы/OpenCore-Builds». В загрузочную EFI сборщик ничего не пишет.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Toggle("Взять из текущей EFI то, что принадлежит этому Mac (SMBIOS, карта USB, патчи, Wi-Fi)", isOn: $b.useCurrent)
                    .disabled(b.running)
            }
            HStack {
                Button { b.build() } label: { Label("Собрать EFI", systemImage: "hammer") }
                    .buttonStyle(.borderedProminent).disabled(b.running)
                if b.running { ProgressView().controlSize(.small); Text("Собираю…").font(.caption) }
                Spacer()
                if let r = b.result {
                    Label(b.validated ? "ocvalidate: без замечаний" : "ocvalidate: есть замечания", systemImage: b.validated ? "checkmark.seal" : "exclamationmark.triangle")
                        .foregroundStyle(b.validated ? .green : .orange).font(.caption)
                    Button("Открыть папку") { NSWorkspace.shared.activateFileViewerSelecting([r.appendingPathComponent("EFI")]) }
                }
            }
            if let err = b.error { Label(err, systemImage: "xmark.octagon.fill").foregroundStyle(.red).textSelection(.enabled) }
            if let r = b.result {
                GroupBox {
                    HStack {
                        Picker("Записать на", selection: $target) {
                            Text("выбери раздел").tag("")
                            ForEach(e.esps) { Text($0.title + ($0.isBoot ? " — ЗАГРУЗОЧНЫЙ" : "")).tag($0.id) }
                        }
                        Button("Записать…") { confirm = true }.disabled(target.isEmpty || e.busy != nil)
                    }
                    Text("Сначала запиши на флешку и загрузись с неё (F12/F11/Esc). Если всё работает — потом перенеси на SSD во вкладке «EFI». Запись сохраняет старые OC и BOOT цели в «Документы/EFI-backups» и проверяет копию.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let m = e.message { Text(m).font(.caption).foregroundStyle(e.failed ? .red : .green) }
                } label: { Text("Проверка на флешке") }
                .alert("Записать сборку?", isPresented: $confirm) {
                    Button("Записать", role: .destructive) { e.copy(fromFolder: r, to: target) }
                    Button("Отмена", role: .cancel) {}
                } message: {
                    Text(e.esps.first(where: { $0.id == target })?.isBoot == true
                         ? "Это раздел, с которого Mac грузится сейчас. Если новая EFI не загрузится, понадобится флешка, чтобы вернуть старую. Лучше сначала проверить на флешке."
                         : "EFI/OC и EFI/BOOT на \(target) будут заменены сборкой. Старые сохранятся в «Документы/EFI-backups».")
                }
            }
            ScrollView {
                Text(b.report.isEmpty ? (b.log.isEmpty ? "Здесь будет ход сборки и отчёт" : b.log) : b.report)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(b.log.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .onAppear { if e.esps.isEmpty { e.refresh() } }
    }
}
