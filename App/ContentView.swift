import SwiftUI
import UniformTypeIdentifiers

/// The window; started by `Main` unless the app was run as a command-line tool.
struct CodeLookApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("CodeLook") {
            ContentView().environmentObject(model).frame(minWidth: 820, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
    }
}

struct ContentView: View {
    var body: some View {
        TabView {
            StatusView().tabItem { Text("状态") }
            InspectView().tabItem { Text("检查文件") }
            CoverageView().tabItem { Text("覆盖情况") }
        }
        .padding(12)
    }
}

// MARK: - Status

struct StatusView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Quick Look 代码预览").font(.title2.bold())
            Text("在 Finder 里选中文件按空格即可。代码 / 配置文件会带语法高亮和行号显示，不再只显示一个文件图标。")
                .foregroundStyle(.secondary)

            ForEach(model.extensions) { ext in
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(ext.title).font(.headline)
                            Spacer()
                            statusBadge(for: ext)
                        }
                        Text(ext.detail).font(.callout).foregroundStyle(.secondary)
                        Text("\(ext.id) · 声明 \(ext.supportedTypes.count) 种类型").font(.caption).foregroundStyle(.tertiary)
                        ForEach(otherCopies(of: ext), id: \.self) { reg in
                            Text("⚠︎ 另一份副本也注册了（可能抢先生效）：\(reg.path)")
                                .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
            }

            configBox

            HStack {
                Button("打开系统设置中的扩展") { SystemTools.openExtensionSettings() }
                Button("重新注册并重置 Quick Look") { model.repair() }.disabled(model.busy)
                Button("刷新") { model.refreshStatus() }
                if model.busy { ProgressView().controlSize(.small) }
            }
            Text("如果预览没变化：先点“重新注册并重置 Quick Look”，再在系统设置 › 通用 › 登录项与扩展 › Quick Look 中确认两个 CodeLook 扩展已勾选。")
                .font(.caption).foregroundStyle(.secondary)

            if !model.repairLog.isEmpty {
                ScrollView {
                    Text(model.repairLog).font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(maxHeight: 160)
                .background(Color(nsColor: .textBackgroundColor))
            }
            Spacer()
        }
        .padding(8)
        // config.yaml is edited elsewhere: show its state again when coming back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshStatus()
        }
    }

    /// Where the settings are and what is wrong with them. There is no settings UI: font, colors,
    /// grammars and file mappings are all edited in config.yaml.
    private var configBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("配置文件").font(.headline)
                    Spacer()
                    if let c = model.config {
                        if !c.problems.isEmpty {
                            Label("\(c.problems.count) 处问题", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        } else if c.exists {
                            Label("已生效", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Label("未创建，使用默认值", systemImage: "circle.dashed").foregroundStyle(.secondary)
                        }
                    }
                }
                Text("字体、配色、语法、文件映射和大小上限都写在这个 YAML 文件里，保存后下一次预览即生效。只有新增扩展名时，要在终端运行下面这条命令重新认领（从源码安装的用 make install）：")
                    .font(.callout).foregroundStyle(.secondary)
                Text("\"\(Bundle.main.bundlePath)/Contents/Resources/install.sh\" --refresh")
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                if let c = model.config {
                    Text("\(c.path) · \(c.font)").font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
                    ForEach(c.problems, id: \.self) { p in
                        Text("⚠︎ \(p)").font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
                HStack {
                    Button(model.config?.exists == false ? "从示例创建并打开" : "打开配置文件") { model.openConfig() }
                    Button("在 Finder 中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: CodeLookConfig.path)])
                    }.disabled(model.config?.exists != true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private func current(of ext: EmbeddedExtension) -> SystemTools.Registration? {
        let regs = model.registrations[ext.id] ?? []
        return regs.first { $0.path == ext.url.path } ?? regs.first
    }

    private func otherCopies(of ext: EmbeddedExtension) -> [SystemTools.Registration] {
        (model.registrations[ext.id] ?? []).filter { $0.path != ext.url.path }
    }

    @ViewBuilder
    private func statusBadge(for ext: EmbeddedExtension) -> some View {
        switch current(of: ext)?.election {
        case nil: Label("未注册", systemImage: "xmark.circle").foregroundStyle(.red)
        case "-": Label("已停用", systemImage: "pause.circle").foregroundStyle(.orange)
        case "=": Label("被其他副本取代", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        default: Label("已启用", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }
}

// MARK: - Inspect one file

struct InspectView: View {
    @EnvironmentObject var model: AppModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("选择文件…") { choose() }
                if let i = model.inspection {
                    Button("用系统 Quick Look 打开") { SystemTools.quickLook(i.url) }
                }
                Spacer()
                Text("也可以把文件拖到这里").foregroundStyle(.secondary).font(.caption)
            }
            if let i = model.inspection {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    GridRow { Text("文件").foregroundStyle(.secondary); Text(i.url.path).textSelection(.enabled) }
                    GridRow { Text("类型").foregroundStyle(.secondary); Text(i.type).textSelection(.enabled) }
                    GridRow { Text("继承自").foregroundStyle(.secondary); Text(i.supertypes.joined(separator: ", ")).font(.caption) }
                    GridRow { Text("覆盖").foregroundStyle(.secondary); Text(i.previewVerdict) }
                    if let p = i.prepared {
                        let d = p.document
                        GridRow { Text("语言").foregroundStyle(.secondary); Text("\(d.languageName)（\(d.reason)）") }
                        GridRow {
                            Text("耗时").foregroundStyle(.secondary)
                            Text(String(format: "读取 + 打开 %.1f ms（%@，只高亮可见行）", p.milliseconds,
                                        (d.syntax.map { "Lithe 语法 \($0)" } ?? "纯文本") as NSString))
                        }
                    }
                    if let e = i.error {
                        GridRow { Text("结果").foregroundStyle(.secondary); Text("不预览：\(e) → 交给系统默认预览").foregroundStyle(.orange) }
                    }
                }
                .font(.callout)
                if let p = i.prepared {
                    CodePreview(prepared: p).border(Color(nsColor: .separatorColor))
                } else {
                    Spacer()
                }
            } else {
                Spacer()
                Text("选择或拖入一个文件，查看它的类型、会由哪个扩展处理，以及预览效果。")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .padding(8)
        .background(dropTargeted ? Color.accentColor.opacity(0.08) : .clear)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in model.inspect(url) } }
            }
            return true
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url { model.inspect(url) }
    }
}

/// The same view the Quick Look extension shows.
struct CodePreview: NSViewRepresentable {
    let prepared: PreparedPreview

    func makeNSView(context: Context) -> CodePreviewView {
        CodePreviewView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    }

    func updateNSView(_ v: CodePreviewView, context: Context) {
        if v.codeView.document !== prepared.document { v.show(prepared) }
    }
}

// MARK: - Coverage

struct CoverageView: View {
    @EnvironmentObject var model: AppModel
    @State private var problemsOnly = true
    @State private var query = ""

    private var rows: [CoverageRow] {
        model.coverage.filter { r in
            (!problemsOnly || r.verdict.isProblem)
                && (query.isEmpty || r.sample.localizedCaseInsensitiveContains(query)
                    || r.language.localizedCaseInsensitiveContains(query) || r.type.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(model.coverage.isEmpty ? "检查本机" : "重新检查") { model.runCoverage() }.disabled(model.busy)
                Toggle("只看非直接支持", isOn: $problemsOnly)
                TextField("筛选", text: $query).textFieldStyle(.roundedBorder).frame(width: 180)
                Spacer()
                if !model.coverage.isEmpty { Text(summary).font(.caption).foregroundStyle(.secondary) }
            }
            Text("为每个已知扩展名 / 文件名建一个临时文件，查询本机给它分配的类型（其他 App 也可能声明类型），再对照两个扩展声明的类型。“经由 / 兜底”依赖 Quick Look 按类型继承关系匹配。")
                .font(.caption).foregroundStyle(.secondary)
            Table(rows) {
                TableColumn("示例") { Text($0.sample).textSelection(.enabled) }.width(min: 120, ideal: 170)
                TableColumn("语言") { Text($0.language) }.width(min: 80, ideal: 110)
                TableColumn("本机类型") { Text($0.type).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                    .width(min: 160, ideal: 300)
                TableColumn("覆盖") { Text($0.verdictText) }.width(min: 90, ideal: 160)
            }
        }
        .padding(8)
    }

    private var summary: String {
        var exact = 0, inherited = 0, fallback = 0, none = 0
        for r in model.coverage {
            switch r.verdict {
            case .exact: exact += 1
            case .inherited: inherited += 1
            case .fallback: fallback += 1
            case .uncovered: none += 1
            }
        }
        return "共 \(model.coverage.count)：直接 \(exact) · 经由父类型 \(inherited) · 兜底 \(fallback) · 未覆盖 \(none)"
    }
}
