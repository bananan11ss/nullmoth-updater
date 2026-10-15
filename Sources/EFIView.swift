import SwiftUI

struct EFITab: View {
    @EnvironmentObject var e: EFIModel
    @State private var confirmCopy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("OpenCore загрузился с: ")
                        + Text(e.esps.first(where: { $0.isBoot })?.id ?? "не определено").bold()
                        + Text(e.ocVersion.map { "  ·  версия \($0)" } ?? "")
                    Spacer()
                    if let b = e.busy { ProgressView().controlSize(.small); Text(b).font(.caption) }
                    Button { e.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).disabled(e.busy != nil)
                }
                if e.esps.isEmpty && e.busy == nil {
                    Text("EFI-разделов не найдено. Вставь флешку с OpenCore и нажми ↻.").foregroundStyle(.secondary)
                }
                ForEach(e.esps) { esp in ESPRow(esp: esp, contents: e.contents[esp.id]) }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Копирует папки EFI/OC и EFI/BOOT с источника на цель, например с флешки на внутренний SSD, чтобы грузиться без флешки. Прежние OC и BOOT цели сначала сохраняются в «Документы/EFI-backups», а копия сверяется с источником. Если что-то не совпало, цель восстанавливается из резервной копии. Другие папки в EFI (Microsoft, Linux) не трогаются.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Picker("Откуда", selection: $e.source) {
                                ForEach(e.esps) { Text($0.title).tag($0.id) }
                            }
                            Image(systemName: "arrow.right")
                            Picker("Куда", selection: $e.target) {
                                ForEach(e.esps) { Text($0.title).tag($0.id) }
                            }
                        }
                        HStack {
                            Button("Перенести EFI…") { confirmCopy = true }
                                .buttonStyle(.borderedProminent)
                                .disabled(e.busy != nil || e.source.isEmpty || e.target.isEmpty || e.source == e.target)
                            if e.source == e.target && !e.source.isEmpty {
                                Text("Источник и цель совпадают").font(.caption).foregroundStyle(.orange)
                            }
                            Spacer()
                            Button("Открыть резервные копии") {
                                try? FileManager.default.createDirectory(at: EFI.backupRoot, withIntermediateDirectories: true)
                                NSWorkspace.shared.open(EFI.backupRoot)
                            }
                        }
                    }
                } label: { Text("Перенос EFI (флешка → SSD и наоборот)") }

                if let msg = e.message {
                    Label(msg, systemImage: e.failed ? "xmark.octagon.fill" : "checkmark.circle.fill")
                        .foregroundStyle(e.failed ? .red : .green).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !e.log.isEmpty {
                    Text(e.log).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        .background(Color(nsColor: .textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("Перенести EFI?", isPresented: $confirmCopy) {
            Button("Перенести", role: .destructive) { e.copy() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("EFI/OC и EFI/BOOT на \(e.target) будут заменены копией с \(e.source). Старые сохранятся в «Документы/EFI-backups». Понадобится пароль администратора.")
        }
    }
}

struct ESPRow: View {
    @EnvironmentObject var e: EFIModel
    let esp: ESP
    let contents: EFIContents?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: esp.isInternal ? "internaldrive" : "externaldrive").foregroundStyle(.secondary)
                    Text(esp.title).bold()
                    if esp.isBoot { tag("загрузочный", .green) }
                    if esp.mounted { tag("смонтирован", .blue) }
                    Spacer()
                    if esp.mounted {
                        Button("Открыть") { e.open(esp.id) }
                        Button("Отключить") { e.unmount(esp.id) }
                    } else {
                        Button("Смонтировать") { e.mount(esp.id) }
                    }
                    Button("Резервная копия") { e.backupNow(esp.id) }
                }
                .disabled(e.busy != nil)
                if let c = contents {
                    if c.hasOC {
                        Text("OpenCore: config.plist \(c.hasConfig ? "есть" : "НЕТ") · \(ByteCountFormatter.string(fromByteCount: c.ocBytes, countStyle: .file)) · BOOT \(c.hasBoot ? "есть" : "нет")\(c.others.isEmpty ? "" : " · ещё в EFI: " + c.others.joined(separator: ", "))")
                            .font(.caption)
                        if !c.kexts.isEmpty {
                            Text("Кексты (\(c.kexts.count)): " + c.kexts.map { $0.replacingOccurrences(of: ".kext", with: "") }.joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if !c.drivers.isEmpty {
                            Text("Драйверы: " + c.drivers.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text("OpenCore здесь нет\(c.others.isEmpty ? "" : " (в EFI: " + c.others.joined(separator: ", ") + ")")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if !esp.mounted {
                    Text("Смонтируй, чтобы увидеть, что внутри").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func tag(_ s: String, _ c: Color) -> some View {
        Text(s).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
            .background(c.opacity(0.18)).foregroundStyle(c).clipShape(Capsule())
    }
}
