import SwiftUI
import UIKit
import Darwin

private let ttAppVersion: String = {
    // GENERATE_INFOPLIST_FILE=YES 总会写入这两个 key，正常路径不会走到兜底。
    // 刻意不硬编码版本号：留一个字面量会在下次升版本时悄悄过期。
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    switch (version, build) {
    case let (v?, b?): return "v\(v) (b\(b))"
    case let (v?, nil): return "v\(v)"
    case let (nil, b?): return "b\(b)"
    default: return "版本未知"
    }
}()

/// 一条测试/常用命令。
///
/// 可编辑、可新增、持久化到 UserDefaults：验收结束后把默认清单换成日常常用命令，
/// 用户也可以自己增删改，改动会保存下来。
struct ChecklistItem: Identifiable, Codable {
    var id = UUID()
    var group: String
    var command: String
    var expect: String
    var isCustom: Bool = false
}

enum ChecklistStore {
    private static let key = "tt.checklist.items.v1"

    /// 内置默认清单（分组首次出现的顺序即展示顺序）
    static func defaults() -> [ChecklistItem] {
        [
            ChecklistItem(group: "基础", command: "pwd", expect: "输出 /"),
            ChecklistItem(group: "基础", command: "ls", expect: "列出根目录，目录带 /"),
            ChecklistItem(group: "基础", command: "ls -la", expect: "含隐藏项的长格式"),
            ChecklistItem(group: "基础", command: "echo hello", expect: "输出 hello"),
            ChecklistItem(group: "基础", command: "date", expect: "真机时间"),
            ChecklistItem(group: "基础", command: "whoami", expect: "mobile"),
            ChecklistItem(group: "基础", command: "uname -a", expect: "系统信息"),
            ChecklistItem(group: "基础", command: "df", expect: "磁盘使用"),

            ChecklistItem(group: "状态码", command: "ls /nonexistent", expect: "错误输出 + 退出码 1"),
            ChecklistItem(group: "状态码", command: "ls -ll", expect: "报不支持的选项，退出码 1"),
            ChecklistItem(group: "状态码", command: "echo a; echo b", expect: "分号顺序执行，两行"),

            ChecklistItem(group: "组合", command: "echo abc | wc", expect: "1 1 4（1 行 1 词 4 字符）"),
            ChecklistItem(group: "组合", command: "ls /etc | head -3", expect: "三行"),
            ChecklistItem(group: "组合", command: "ls /bin | grep df", expect: "df"),
            ChecklistItem(group: "组合", command: "cd bin && ls", expect: "df、ps"),
            ChecklistItem(group: "组合", command: "ls /nonexistent || echo fallback", expect: "fallback"),
            ChecklistItem(group: "组合", command: "cd /etc; pwd", expect: "/etc"),
            ChecklistItem(group: "组合", command: "echo c b a | sort | tr a-z A-Z", expect: "A B C 三行"),

            ChecklistItem(group: "重定向", command: "echo hello > /tmp/tt1.txt", expect: "提示已写入，终端不再显示"),
            ChecklistItem(group: "重定向", command: "cat /tmp/tt1.txt", expect: "hello"),
            ChecklistItem(group: "重定向", command: "echo world >> /tmp/tt1.txt", expect: "追加"),
            ChecklistItem(group: "重定向", command: "cat /tmp/tt1.txt", expect: "两行 hello/world"),
            ChecklistItem(group: "重定向", command: "wc < /tmp/tt1.txt", expect: "输入重定向计数"),
            ChecklistItem(group: "重定向", command: "echo \"a>b\"", expect: "引号内 > 不触发重定向"),

            ChecklistItem(group: "文件", command: "touch /tmp/tt2.txt", expect: "无输出，退出码 0"),
            ChecklistItem(group: "文件", command: "ls -l /tmp/tt2.txt", expect: "列出新建的文件"),
            ChecklistItem(group: "文件", command: "mkdir -p /tmp/ttd", expect: "创建目录"),
            ChecklistItem(group: "文件", command: "cp /tmp/tt1.txt /tmp/tt3.txt", expect: "复制文件"),
            ChecklistItem(group: "文件", command: "mv /tmp/tt3.txt /tmp/tt4.txt", expect: "改名"),
            ChecklistItem(group: "文件", command: "stat /tmp/tt4.txt", expect: "文件元信息"),
            ChecklistItem(group: "文件", command: "rm -f /tmp/tt2.txt /tmp/tt4.txt", expect: "删除文件"),
            ChecklistItem(group: "文件", command: "rm -rf /tmp/ttd", expect: "递归删除目录"),
            ChecklistItem(group: "文件", command: "find /tmp -name tt1.txt -type f", expect: "查找匹配文件"),
            ChecklistItem(group: "文件", command: "du -sh /tmp", expect: "目录占用"),

            ChecklistItem(group: "目录", command: "cd bin", expect: "无输出，退出码 0"),
            ChecklistItem(group: "目录", command: "pwd", expect: "/bin"),
            ChecklistItem(group: "目录", command: "cd ..", expect: "回到上一级"),
            ChecklistItem(group: "目录", command: "pwd", expect: "/")
        ]
    }

    static func load() -> [ChecklistItem] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([ChecklistItem].self, from: data),
              !items.isEmpty else {
            return defaults()
        }
        return items
    }

    static func save(_ items: [ChecklistItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// 保持分组首次出现的顺序
    static func groups(of items: [ChecklistItem]) -> [String] {
        var seen: [String] = []
        for item in items where !seen.contains(item.group) {
            seen.append(item.group)
        }
        return seen
    }
}

/// 清单条目的编辑/新增弹窗。两条路径共用一套表单。
struct ChecklistEditorSheet: View {
    let isNew: Bool
    let onSave: (ChecklistItem) -> Void
    let onDelete: (() -> Void)?
    let onCancel: () -> Void

    @State private var group: String
    @State private var command: String
    @State private var expect: String
    @State private var isCustom: Bool

    init(item: ChecklistItem,
         isNew: Bool,
         onSave: @escaping (ChecklistItem) -> Void,
         onDelete: (() -> Void)? = nil,
         onCancel: @escaping () -> Void) {
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        _group = State(initialValue: item.group)
        _command = State(initialValue: item.command)
        _expect = State(initialValue: item.expect)
        _isCustom = State(initialValue: item.isCustom)
    }

    private var canSave: Bool {
        !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 已有分组做快捷选择，避免每次手打
    private var knownGroups: [String] {
        ChecklistStore.groups(of: ChecklistStore.load())
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("命令")) {
                    TextField("例如 echo hello", text: $command)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                }
                Section(header: Text("分类")) {
                    TextField("例如 基础", text: $group)
                    if !knownGroups.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(knownGroups, id: \.self) { name in
                                    Button {
                                        group = name
                                    } label: {
                                        Text(name)
                                            .font(.caption)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(group == name ? Color.green.opacity(0.85) : Color.gray.opacity(0.35),
                                                        in: Capsule())
                                            .foregroundColor(.white)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                Section(header: Text("期望结果")) {
                    TextField("例如 输出 hello", text: $expect)
                }
                Section {
                    Toggle("标记为自定义命令", isOn: $isCustom)
                }
                if let onDelete = onDelete {
                    Section {
                        Button(role: .destructive, action: onDelete) {
                            Label("删除这条", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "添加命令" : "编辑命令")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(ChecklistItem(group: group.trimmingCharacters(in: .whitespacesAndNewlines),
                                             command: command.trimmingCharacters(in: .whitespacesAndNewlines),
                                             expect: expect,
                                             isCustom: isCustom || isNew))
                    }
                    .disabled(!canSave)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - 彩色显示

/// 深色终端配色。正文用柔和灰白（对比度约 13.5:1，超过 WCAG AAA）。
/// 颜色只作辅助：每种状态都同时带文字前缀，去掉颜色依然可读。
private let terminalFont = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)

private enum TerminalPalette {
    static let background = UIColor.black
    static let defaultText = UIColor(red: 0.831, green: 0.831, blue: 0.831, alpha: 1) // #D4D4D4
    static let command = UIColor(red: 0.373, green: 0.843, blue: 0.843, alpha: 1)     // #5FD7D7
    static let status = UIColor(red: 0.541, green: 0.608, blue: 0.659, alpha: 1)      // #8A9BA8
    static let success = UIColor(red: 0.482, green: 0.788, blue: 0.435, alpha: 1)     // #7BC96F
    static let failure = UIColor(red: 0.878, green: 0.424, blue: 0.459, alpha: 1)     // #E06C75
    static let warning = UIColor(red: 0.898, green: 0.753, blue: 0.482, alpha: 1)     // #E5C07B
    static let pathTint = UIColor(red: 0.612, green: 0.863, blue: 0.996, alpha: 1)    // #9CDCFE
    static let diagnostic = UIColor(red: 0.494, green: 0.478, blue: 0.635, alpha: 1) // #7E7AA2

    static func color(for kind: TranscriptSegment.Kind) -> UIColor {
        switch kind {
        case .banner: return defaultText
        case .command: return command
        case .engineStatus: return status
        case .output: return defaultText
        case .success: return success
        case .failure: return failure
        case .warning: return warning
        case .path: return pathTint
        case .diagnostic: return diagnostic
        }
    }
}

/// 终端里的一段文本及其语义类别。
struct TranscriptSegment: Identifiable {
    let id = UUID()
    enum Kind {
        case banner        // 启动横幅
        case command       // › 用户输入
        case engineStatus  // [TT] 执行引擎：…
        case output        // 程序输出
        case success       // [TT] 退出码：0
        case failure       // 非零退出码 / 启动失败记录
        case warning       // [TT] 诊断：…
        case path          // [TT] 已写入 …
        case diagnostic    // 自检等 TT 自己的信息
    }
    let kind: Kind
    let text: String
}

/// 把多行文本按"TT 自己产出的固定前缀"拆成语义片段。
///
/// 关键点：只匹配本项目代码里写死的那几个前缀（`[TT] 退出码：` 等），
/// **不做关键词匹配**——所以 `ls /var/log/error/` 的路径、
/// `grep error app.log` 输出里的 "error" 都仍然是普通正文色。
private enum TranscriptClassifier {
    static func classify(_ block: String, fallback: TranscriptSegment.Kind = .output) -> [TranscriptSegment] {
        block.components(separatedBy: "\n").map { line in
            TranscriptSegment(kind: kind(of: line, fallback: fallback), text: line)
        }
    }

    private static func kind(of line: String, fallback: TranscriptSegment.Kind) -> TranscriptSegment.Kind {
        if line.hasPrefix("› ") { return .command }
        if line.hasPrefix("[TT] 退出码：") { return line.contains("退出码：0") ? .success : .failure }
        if line.hasPrefix("[TT] 执行引擎：") { return .engineStatus }
        if line.hasPrefix("[TT] 诊断：") { return .warning }
        if line.hasPrefix("[TT] 已写入 ") { return .path }
        if line.hasPrefix("[TT] Shell 启动失败记录：") { return .failure }
        if line.hasPrefix("[TT]   ") { return .failure }   // 失败记录的缩进续行
        if line.hasPrefix("[TT] ") { return .diagnostic }
        if line.hasPrefix("TT_FORK_") || line.hasPrefix("-- ") || line.contains(": iter") { return .diagnostic }
        return fallback
    }
}

/// ANSI SGR 着色后的一段文本。
private struct ANSISpan {
    let text: String
    let color: UIColor?
    let bold: Bool
}

/// 解析 ANSI SGR 颜色序列。
///
/// 安全约束（对应"不完整转义序列不得污染后续文字"的要求）：
/// - 状态**不跨片段延续**：调用方对每个片段重新调用，颜色天然隔离
/// - 序列被截断（没有终止字母）时按普通文本原样输出，且**不改变**颜色状态
/// - 不支持的序列原样保留，不吞字符
/// - 返回的纯文本已剥离转义符，供"复制全部"使用
private enum ANSIParser {
    private static func ansiColor(_ code: Int) -> UIColor? {
        let palette: [UIColor] = [
            UIColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1),   // 30 black
            UIColor(red: 0.878, green: 0.424, blue: 0.459, alpha: 1), // 31 red
            UIColor(red: 0.482, green: 0.788, blue: 0.435, alpha: 1), // 32 green
            UIColor(red: 0.898, green: 0.753, blue: 0.482, alpha: 1), // 33 yellow
            UIColor(red: 0.373, green: 0.843, blue: 0.843, alpha: 1), // 34 blue
            UIColor(red: 0.788, green: 0.478, blue: 0.788, alpha: 1), // 35 magenta
            UIColor(red: 0.478, green: 0.788, blue: 0.788, alpha: 1), // 36 cyan
            UIColor(red: 0.831, green: 0.831, blue: 0.831, alpha: 1)  // 37 white
        ]
        let bright: [UIColor] = [
            UIColor(red: 0.42, green: 0.42, blue: 0.42, alpha: 1),
            UIColor(red: 0.96, green: 0.55, blue: 0.58, alpha: 1),
            UIColor(red: 0.60, green: 0.90, blue: 0.55, alpha: 1),
            UIColor(red: 0.96, green: 0.85, blue: 0.60, alpha: 1),
            UIColor(red: 0.55, green: 0.90, blue: 0.95, alpha: 1),
            UIColor(red: 0.92, green: 0.62, blue: 0.92, alpha: 1),
            UIColor(red: 0.62, green: 0.92, blue: 0.92, alpha: 1),
            UIColor.white
        ]
        if code >= 30 && code <= 37 { return palette[code - 30] }
        if code >= 90 && code <= 97 { return bright[code - 90] }
        return nil
    }

    static func parse(_ input: String) -> (spans: [ANSISpan], plain: String) {
        let chars = Array(input)
        var spans: [ANSISpan] = []
        var plain = ""
        var pending = ""
        var color: UIColor? = nil
        var bold = false
        var index = 0

        func emit(_ text: String) {
            guard !text.isEmpty else { return }
            plain += text
            spans.append(ANSISpan(text: text, color: color, bold: bold))
        }

        while index < chars.count {
            let character = chars[index]
            guard character == "\u{1B}", index + 1 < chars.count, chars[index + 1] == "[" else {
                pending.append(character)
                index += 1
                continue
            }
            // 收集 CSI 序列直到终止字符
            var cursor = index + 2
            var body = ""
            var terminator: Character? = nil
            while cursor < chars.count {
                let c = chars[cursor]
                if c.isLetter || c == "@" {
                    terminator = c
                    break
                }
                if c == "\u{1B}" { break }
                body.append(c)
                cursor += 1
            }
            emit(pending)
            pending = ""

            if let t = terminator, t == "m", !body.isEmpty {
                applySGR(body, color: &color, bold: &bold)
                index = cursor + 1
                continue
            }
            if terminator == nil {
                // 序列被截断：剩余部分原样输出，状态不变
                pending = "\u{1B}[" + body
                index = chars.count
                continue
            }
            // 不支持的序列：原样保留，不吞字符
            pending = "\u{1B}[" + body + String(terminator!)
            index = cursor + 1
        }
        emit(pending)
        return (spans, plain)
    }

    private static func applySGR(_ body: String, color: inout UIColor?, bold: inout Bool) {
        var codes = body.components(separatedBy: ";").map { String($0) }
        if codes.isEmpty { codes = ["0"] }
        if codes[0].isEmpty { codes[0] = "0" }   // ";31" 视作 "0;31"
        for code in codes {
            switch code {
            case "0": color = nil; bold = false
            case "1": bold = true
            case "22": bold = false
            case "39": color = nil
            default:
                if let number = Int(code), let resolved = ansiColor(number) { color = resolved }
            }
        }
    }
}

/// 把结构化片段渲染成带颜色的富文本。
private enum TranscriptRenderer {
    static func attributed(_ segments: [TranscriptSegment], font: UIFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (offset, segment) in segments.enumerated() {
            if offset > 0 {
                result.append(NSAttributedString(string: "\n", attributes: baseAttributes(font: font, color: TerminalPalette.defaultText)))
            }
            append(segment.text, kind: segment.kind, to: result, font: font)
        }
        return result
    }

    private static func baseAttributes(font: UIFont, color: UIColor) -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: color
        ]
    }

    /// output 片段额外走 ANSI 解析，其余按语义类别整体着色。
    private static func append(_ text: String, kind: TranscriptSegment.Kind, to result: NSMutableAttributedString, font: UIFont) {
        guard kind == .output else {
            result.append(NSAttributedString(string: text, attributes: baseAttributes(font: font, color: TerminalPalette.color(for: kind))))
            return
        }
        let parsed = ANSIParser.parse(text)
        for span in parsed.spans {
            let color = span.color ?? TerminalPalette.defaultText
            var attributes = baseAttributes(font: font, color: color)
            if span.bold {
                let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) ?? font.fontDescriptor
                attributes[.font] = UIFont(descriptor: descriptor, size: font.pointSize)
            }
            result.append(NSAttributedString(string: span.text, attributes: attributes))
        }
    }
}

struct ContentView: View {
    @State private var command = ""
    /// 结构化终端记录：每一行都带语义类别，渲染时才上色。
    /// 改为结构化是为了"按来源着色"——TT 自己的消息和程序输出天然可分。
    @State private var transcript: [TranscriptSegment] = TranscriptClassifier.classify("""
    TT 终端 · \(ttAppVersion)
    文字长按可选择与复制。
    命令由应用内置 mksh Shell 真实执行（系统不含 /bin/sh）；启动失败时自动降级内置解释器。
    """, fallback: .banner)
    @State private var history: [String] = []
    @State private var showHistory = false
    @State private var showChecklist = false
    @State private var checklist: [ChecklistItem] = ChecklistStore.load()
    @State private var checklistFilter: String = "全部"
    @State private var checklistEditing = false
    @State private var editingItem: ChecklistItem?
    @State private var newItemDraft: ChecklistItem?
    @State private var isExecuting = false
    @State private var didRunDiagnostics = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(isExecuting ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)

                Text("TT 终端")
                    .font(.headline.monospaced())

                Text(ttAppVersion)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button {
                    showHistory = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 17, weight: .medium))
                }
                .accessibilityLabel("输入历史")
                .accessibilityIdentifier("tt.history")

                Button(action: copyAll) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 16, weight: .medium))
                }
                .accessibilityLabel("复制全部")
                .accessibilityIdentifier("tt.copyAll")

                Button(action: clearTranscript) {
                    Image(systemName: "trash")
                        .font(.system(size: 16, weight: .medium))
                }
                .accessibilityLabel("清空终端")
                .accessibilityIdentifier("tt.clear")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(red: 0.12, green: 0.13, blue: 0.15))

            ScrollViewReader { proxy in
                ScrollView {
                    SelectableTerminalTextView(segments: $transcript)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("transcript")
                }
                .background(Color.black)
                .onChange(of: transcript.count) { _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("transcript", anchor: .bottom)
                    }
                }
            }

            HStack(spacing: 8) {
                Text("›")
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundColor(.green)

                TextField("输入命令，例如 pwd、ls、date", text: $command)
                    .font(.system(size: 15, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .submitLabel(.send)
                    .onSubmit(submitCommand)
                    .accessibilityIdentifier("tt.command.input")

                Button {
                    showChecklist = true
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 17, weight: .medium))
                }
                .accessibilityLabel("测试清单")
                .accessibilityIdentifier("tt.checklist")

                Button(action: submitCommand) {
                    if isExecuting {
                        ProgressView()
                            .tint(.green)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 25))
                    }
                }
                .accessibilityLabel("执行命令")
                .accessibilityIdentifier("tt.command.send")
                .disabled(isExecuting || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(red: 0.12, green: 0.13, blue: 0.15))
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear { runStartupDiagnostics() }
        .sheet(isPresented: $showHistory) {
            NavigationView {
                Group {
                    if history.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "clock")
                                .font(.system(size: 34))
                                .foregroundColor(.secondary)
                            Text("还没有输入记录")
                                .foregroundColor(.secondary)
                        }
                    } else {
                        List(Array(history.reversed().enumerated()), id: \.offset) { entry in
                            Button {
                                command = entry.element
                                showHistory = false
                            } label: {
                                Text(entry.element)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .navigationTitle("输入历史")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { showHistory = false }
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showChecklist) {
            NavigationView {
                List {
                    Section {
                        Text(checklistEditing
                             ? "编辑模式：点一条可修改，左滑可删除。改完记得点保存。"
                             : "点一条即执行。跑完用工具栏的复制按钮把全部结果发回。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    // 分类筛选
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(["全部"] + ChecklistStore.groups(of: checklist), id: \.self) { group in
                                    Button {
                                        checklistFilter = group
                                    } label: {
                                        Text(group)
                                            .font(.caption)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(
                                                checklistFilter == group ? Color.green.opacity(0.85) : Color.gray.opacity(0.35),
                                                in: Capsule()
                                            )
                                            .foregroundColor(.white)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    // 按分类分组展示
                    ForEach(ChecklistStore.groups(of: checklist), id: \.self) { group in
                        if checklistFilter == "全部" || checklistFilter == group {
                            Section(group) {
                                ForEach(checklist.filter { $0.group == group }) { item in
                                    Button {
                                        if checklistEditing {
                                            editingItem = item
                                        } else {
                                            showChecklist = false
                                            // 等面板收起再执行，避免和 sheet 转场动画抢状态
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                                execute(item.command)
                                            }
                                        }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 3) {
                                            HStack {
                                                Text(item.command)
                                                    .font(.system(.body, design: .monospaced))
                                                    .foregroundColor(.primary)
                                                Spacer()
                                                if item.isCustom {
                                                    Text("自定义")
                                                        .font(.caption2)
                                                        .padding(.horizontal, 6)
                                                        .padding(.vertical, 2)
                                                        .background(Color.blue.opacity(0.35), in: Capsule())
                                                        .foregroundColor(.white)
                                                }
                                                if checklistEditing {
                                                    Image(systemName: "pencil")
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                }
                                            }
                                            Text("期望：\(item.expect)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        .padding(.vertical, 2)
                                    }
                                    .swipeActions {
                                        Button(role: .destructive) {
                                            checklistDelete(item)
                                        } label: {
                                            Label("删除", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .navigationTitle("命令清单")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Menu {
                            Button {
                                newItemDraft = ChecklistItem(group: "自定义", command: "", expect: "")
                            } label: {
                                Label("添加命令", systemImage: "plus")
                            }
                            Button {
                                checklistRestoreDefaults()
                            } label: {
                                Label("恢复默认清单", systemImage: "arrow.counterclockwise")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        Button(checklistEditing ? "完成编辑" : "编辑") {
                            if checklistEditing { saveChecklist() }
                            checklistEditing.toggle()
                        }
                        Button("完成") {
                            if checklistEditing { saveChecklist() }
                            checklistEditing = false
                            showChecklist = false
                        }
                    }
                }
            }
            .preferredColorScheme(.dark)
            // 编辑/新增弹窗挂在清单面板内部：
            // 若挂在 ContentView 上，清单 sheet 仍在前台时再 present 会被系统忽略。
            .sheet(item: $editingItem) { item in
                ChecklistEditorSheet(item: item,
                                     isNew: false,
                                     onSave: { updated in
                                         checklistUpsert(updated)
                                         editingItem = nil
                                     },
                                     onDelete: nil,
                                     onCancel: { editingItem = nil })
            }
            .sheet(item: $newItemDraft) { item in
                ChecklistEditorSheet(item: item,
                                     isNew: true,
                                     onSave: { updated in
                                         checklistUpsert(updated)
                                         newItemDraft = nil
                                     },
                                     onDelete: nil,
                                     onCancel: { newItemDraft = nil })
            }
        }
    }

    private func submitCommand() {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isExecuting else { return }
        command = ""
        execute(text)
    }

    /// Runs one command, recording it in history and the transcript.
    /// Shared by the input field and the checklist so both take the same path.
    private func execute(_ text: String) {
        guard !text.isEmpty, !isExecuting else { return }

        history.append(text)
        if history.count > 50 {
            history.removeFirst(history.count - 50)
        }

        if text == "clear" {
            clearTranscript()
            return
        }

        // 空行做视觉分隔；命令与状态各自显式标注类别，不靠解析文本
        transcript.append(TranscriptSegment(kind: .banner, text: ""))
        transcript.append(TranscriptSegment(kind: .command, text: "› \(text)"))
        transcript.append(TranscriptSegment(kind: .engineStatus, text: "[TT] 正在执行……"))
        isExecuting = true

        ShellCommandRunner.run(text) { result in
            DispatchQueue.main.async {
                transcript.append(contentsOf: TranscriptClassifier.classify(result))
                isExecuting = false
            }
        }
    }

    private func runStartupDiagnostics() {
        guard !didRunDiagnostics else { return }
        didRunDiagnostics = true
        DispatchQueue.global(qos: .userInitiated).async {
            let report = EnvironmentProbe.fullReport()
            DispatchQueue.main.async {
                transcript.append(TranscriptSegment(kind: .banner, text: ""))
                // 自检整段都是 TT 自己的信息，统一标为诊断色
                transcript.append(contentsOf: TranscriptClassifier.classify(report, fallback: .diagnostic))
            }
        }
    }

    /// 复制全部：输出纯文本，ANSI 转义符已剥离
    private func copyAll() {
        UIPasteboard.general.string = transcript.map { segment -> String in
            segment.kind == .output ? ANSIParser.parse(segment.text).plain : segment.text
        }.joined(separator: "\n")
    }

    private func clearTranscript() {
        transcript = TranscriptClassifier.classify("TT 终端已清空。\n输入 help 查看内置解释器支持的命令。", fallback: .banner)
    }

    // MARK: - 清单管理

    private func persistChecklist() {
        ChecklistStore.save(checklist)
    }

    private func saveChecklist() {
        persistChecklist()
    }

    private func checklistUpsert(_ item: ChecklistItem) {
        if let index = checklist.firstIndex(where: { $0.id == item.id }) {
            checklist[index] = item
        } else {
            checklist.append(item)
        }
        persistChecklist()
    }

    private func checklistDelete(_ item: ChecklistItem) {
        checklist.removeAll { $0.id == item.id }
        // 该分类已删空时退回"全部"，否则筛选条会指向一个不存在的分类
        if !checklist.contains(where: { $0.group == item.group }),
           checklistFilter == item.group {
            checklistFilter = "全部"
        }
        persistChecklist()
    }

    private func checklistRestoreDefaults() {
        checklist = ChecklistStore.defaults()
        checklistFilter = "全部"
        persistChecklist()
    }
}

/// UITextView provides native iOS long-press selection handles and the Copy menu.
/// 富文本渲染不影响这些原生能力：长按选择、拖动手柄、复制菜单都照常工作，
/// 复制出来的仍是纯文本。
private struct SelectableTerminalTextView: UIViewRepresentable {
    @Binding var segments: [TranscriptSegment]

    func makeUIView(context: Context) -> SelectableTerminalUITextView {
        let view = SelectableTerminalUITextView()
        view.backgroundColor = .clear
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.textContainerInset = UIEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        view.textContainer.lineFragmentPadding = 0
        view.font = terminalFont
        view.tintColor = .green
        view.accessibilityIdentifier = "tt.terminal.text"
        view.attributedText = TranscriptRenderer.attributed(segments, font: terminalFont)
        return view
    }

    func updateUIView(_ uiView: SelectableTerminalUITextView, context: Context) {
        let plain = plainText(segments)
        guard uiView.attributedText.string != plain else { return }
        // 记住选区，重建后恢复，避免每次追加输出都把用户的选区清掉
        let previousSelection = uiView.selectedRange
        let previousLength = (uiView.attributedText.string as NSString).length
        let selectionWasAtEnd = previousSelection.location >= previousLength
        uiView.attributedText = TranscriptRenderer.attributed(segments, font: terminalFont)
        if selectionWasAtEnd {
            uiView.selectedRange = NSRange(location: (uiView.attributedText.string as NSString).length, length: 0)
        } else if previousSelection.location + previousSelection.length <= previousLength {
            uiView.selectedRange = previousSelection
        }
    }

    /// 用于比较和测量的纯文本（不含颜色、不含 ANSI 转义符）
    private func plainText(_ segments: [TranscriptSegment]) -> String {
        segments.map { segment -> String in
            if segment.kind == .output {
                return ANSIParser.parse(segment.text).plain
            }
            return segment.text
        }.joined(separator: "\n")
    }
}

private final class SelectableTerminalUITextView: UITextView {
    private var lastMeasuredWidth: CGFloat = 0

    override var intrinsicContentSize: CGSize {
        let width = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width
        let measured = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: UIView.noIntrinsicMetric, height: max(measured.height, 1))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if abs(bounds.width - lastMeasuredWidth) > 0.5 {
            lastMeasuredWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

/// Result of one spawned process.
private struct SpawnResult {
    let spawnErrno: Int32   // 0 = process created; otherwise errno from posix_spawn
    let exitCode: Int32     // valid when spawnErrno == 0
    let output: String      // merged stdout + stderr
}

/// Shared low-level launcher: posix_spawn with stdout/stderr merged into a pipe.
private enum ProcessLauncher {
    static func spawnCapturing(path: String, arguments: [String], environment: [String: String]? = nil, stdinData: Data? = nil) -> SpawnResult {
        var pipeFDs: [Int32] = [0, 0]
        guard pipe(&pipeFDs) == 0 else {
            return SpawnResult(spawnErrno: errno, exitCode: -1, output: "[TT] 创建输出管道失败：\(String(cString: strerror(errno)))")
        }

        var actions: posix_spawn_file_actions_t?
        let actionsStatus = posix_spawn_file_actions_init(&actions)
        guard actionsStatus == 0, actions != nil else {
            close(pipeFDs[0])
            close(pipeFDs[1])
            return SpawnResult(spawnErrno: actionsStatus, exitCode: -1, output: "[TT] 初始化文件操作失败：\(String(cString: strerror(actionsStatus)))")
        }
        posix_spawn_file_actions_adddup2(&actions, pipeFDs[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, pipeFDs[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, pipeFDs[0])
        posix_spawn_file_actions_addclose(&actions, pipeFDs[1])

        // 管道输入：写入临时文件并作为子进程 stdin（临时文件避免大输出时写满 pipe 缓冲区而阻塞）
        var stdinTempURL: URL?
        if let stdinData = stdinData, !stdinData.isEmpty {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("tt-stdin-\(UUID().uuidString)")
            if (try? stdinData.write(to: url)) != nil {
                let fd = open(url.path, O_RDONLY)
                if fd >= 0 {
                    posix_spawn_file_actions_adddup2(&actions, fd, STDIN_FILENO)
                    posix_spawn_file_actions_addclose(&actions, fd)
                    stdinTempURL = url
                } else {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }

        var childPID: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(path)]
        for argument in arguments {
            argv.append(strdup(argument))
        }
        argv.append(nil)
        var envPointers: [UnsafeMutablePointer<CChar>?] = []
        if let environment = environment {
            for (key, value) in environment {
                envPointers.append(strdup("\(key)=\(value)"))
            }
            envPointers.append(nil)
        }
        let spawnStatus: Int32 = argv.withUnsafeMutableBufferPointer { buffer in
            envPointers.withUnsafeMutableBufferPointer { envBuffer in
                posix_spawn(&childPID, path, &actions, nil, buffer.baseAddress!,
                            environment == nil ? environ : envBuffer.baseAddress)
            }
        }
        for pointer in argv {
            free(pointer)
        }
        for pointer in envPointers {
            free(pointer)
        }

        posix_spawn_file_actions_destroy(&actions)
        close(pipeFDs[1])
        if let stdinTempURL = stdinTempURL {
            try? FileManager.default.removeItem(at: stdinTempURL)
        }

        guard spawnStatus == 0 else {
            close(pipeFDs[0])
            return SpawnResult(spawnErrno: spawnStatus, exitCode: -1, output: "")
        }

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let bytesRead = read(pipeFDs[0], &buffer, buffer.count)
            if bytesRead > 0 {
                output.append(contentsOf: buffer[0..<bytesRead])
            } else if bytesRead == 0 {
                break
            } else if errno != EINTR {
                break
            }
        }
        close(pipeFDs[0])

        var waitStatus: Int32 = 0
        var waitResult: Int32 = -1
        // 被信号打断（EINTR）时重试，避免读到未初始化的退出状态
        repeat {
            waitResult = waitpid(childPID, &waitStatus, 0)
        } while waitResult < 0 && errno == EINTR
        let exitCode: Int32 = waitResult == childPID
            ? ((waitStatus & 0x7f) == 0 ? ((waitStatus >> 8) & 0xff) : 128 + (waitStatus & 0x7f))
            : -1
        return SpawnResult(spawnErrno: 0, exitCode: exitCode, output: String(decoding: output, as: UTF8.self))
    }
}

/// Executes commands through the device's /bin/sh and returns real stdout/stderr.
/// Splits a command line into segments joined by shell operators.
/// mksh on this device SIGBUSes when it forks more than once, so pipelines and
/// `&&` chains are split by the app and each segment runs as its own single
/// command; `|` is honored by piping the previous segment's stdout into the
/// next segment's stdin.
private enum CommandSplitter {
    struct Segment {
        let text: String           // command only, redirections stripped
        let separatorAfter: String // what connects this segment to the next one
        let stdinPath: String?     // `< file`
        let stdoutPath: String?    // `> file` / `>> file`
        let stdoutAppend: Bool     // true for `>>`
    }

    /// Pulls top-level `<` / `>` / `>>` redirections out of a single command.
    /// Quoted occurrences are left alone so `echo "a>b"` still prints `a>b`.
    static func extractRedirections(_ input: String) -> (command: String, stdin: String?, stdout: String?, append: Bool) {
        var command = ""
        var stdinPath: String?
        var stdoutPath: String?
        var append = false
        var quote: Character?
        var pendingRedirect: Character?
        var pendingAppend = false

        var index = input.startIndex
        while index < input.endIndex {
            let character = input[index]
            let next = input.index(after: index)

            if let activeQuote = quote {
                command.append(character)
                if character == activeQuote { quote = nil }
                index = next
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                command.append(character)
                index = next
                continue
            }
            if pendingRedirect != nil {
                if character.isWhitespace {
                    index = next
                    continue  // skip spaces between operator and target
                }
                // 注意：必须按当前字符推进 index。早前一版误写成 index = next，
                // 而 next 是外层循环开头算出的常量，导致 target 无限增长、App 卡死。
                var target = ""
                while index < input.endIndex,
                      !input[index].isWhitespace,
                      input[index] != "<",
                      input[index] != ">" {
                    target.append(input[index])
                    index = input.index(after: index)
                }
                if pendingRedirect == ">" {
                    stdoutPath = target
                    append = pendingAppend
                } else {
                    stdinPath = target
                }
                pendingRedirect = nil
                pendingAppend = false
                continue
            }
            if character == ">" {
                pendingRedirect = ">"
                if next < input.endIndex && input[next] == ">" {
                    pendingAppend = true
                    index = input.index(after: next)
                    continue
                }
                index = next
                continue
            }
            if character == "<" {
                pendingRedirect = "<"
                index = next
                continue
            }
            command.append(character)
            index = next
        }

        return (command.trimmingCharacters(in: .whitespacesAndNewlines), stdinPath, stdoutPath, append)
    }

    static func split(_ input: String) -> [Segment] {
        var result: [Segment] = []
        var current = ""
        var quote: Character?

        func finish(with separator: String) {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let parsed = extractRedirections(trimmed)
                // `>` already ended the segment in split(); a trailing `>` with no
                // target would leave an empty command, so fall back to raw text.
                let commandText = parsed.command.isEmpty ? trimmed : parsed.command
                result.append(Segment(text: commandText,
                                      separatorAfter: separator,
                                      stdinPath: parsed.stdin,
                                      stdoutPath: parsed.stdout,
                                      stdoutAppend: parsed.append))
            }
            current = ""
        }

        var index = input.startIndex
        // 防御：解析器必须单调推进。万一将来再出现"索引没前进"的错误，
        // 也要在这里停下来，绝不能让解析本身把 App 卡死。
        var guardCounter = 0
        let iterationLimit = max(128, input.count * 8)
        while index < input.endIndex {
            guardCounter += 1
            if guardCounter > iterationLimit { break }
            let character = input[index]
            let next = input.index(after: index)

            if let activeQuote = quote {
                current.append(character)
                if character == activeQuote { quote = nil }
                index = next
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                current.append(character)
                index = next
                continue
            }
            if next < input.endIndex {
                let pair = String([character, input[next]])
                if pair == "&&" || pair == "||" {
                    finish(with: pair)
                    index = input.index(after: next)
                    continue
                }
            }
            if character == "|" {
                finish(with: "|")
                index = next
                continue
            }
            if character == ";" {
                finish(with: ";")
                index = next
                continue
            }
            current.append(character)
            index = next
        }
        finish(with: "")
        return result
    }
}

/// Resolves a redirection target relative to the terminal's current directory
/// (which `cd` may have changed), mirroring shell behaviour.
private func resolvePath(_ path: String) -> String {
    if path.hasPrefix("/") { return path }
    var buffer = [CChar](repeating: 0, count: 4096)
    let cwd = getcwd(&buffer, buffer.count).map { _ in String(cString: buffer) } ?? "/"
    return (cwd as NSString).appendingPathComponent(path)
}

/// Writes a command's captured stdout to a file, honouring `>` vs `>>`.
/// Returns a short confirmation line, or nil when the write fails.
private func writeRedirect(_ text: String, to path: String, append: Bool) -> String? {
    let url = URL(fileURLWithPath: path)
    let data = Data(text.utf8)
    do {
        if append {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url)
            }
        } else {
            try data.write(to: url, options: .atomic)
        }
        return "[TT] 已写入 \(append ? "追加到 " : "")\(path)（\(data.count) 字节）"
    } catch {
        return nil
    }
}

/// Executes commands through the bundled mksh and returns real stdout/stderr.
/// fork() is unusable on the target device (SIGBUS on the first call, confirmed by
/// the ttfork probe), so sequencing, pipes and redirections are implemented here:
/// each segment runs as its own single command, which mksh can exec without forking.
private enum ShellCommandRunner {
    static func run(_ command: String, completion: @escaping (String) -> Void) {
        let segments = CommandSplitter.split(command)
        DispatchQueue.global(qos: .userInitiated).async {
            guard !segments.isEmpty else {
                completion("[TT] 执行引擎：内置解释器\n(空命令)\n[TT] 退出码：0")
                return
            }

            let mkshPath = (Bundle.main.bundlePath as NSString).appendingPathComponent("ttbin/mksh")
            let binPath = (Bundle.main.bundlePath as NSString).appendingPathComponent("ttbin")
            let environment = ["PATH": "\(binPath):/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "dumb"]

            var outputLines: [String] = []
            var pipedInput: Data?
            var lastExitCode: Int32 = 0
            var usedBuiltinCd = false
            var failedToSpawn = false

            for (offset, segment) in segments.enumerated() {
                let precedingSeparator = offset > 0 ? segments[offset - 1].separatorAfter : ""
                if precedingSeparator == "&&" && lastExitCode != 0 { break }
                if precedingSeparator == "||" && lastExitCode == 0 { break }
                let receivesPipeInput = precedingSeparator == "|"

                // cd 必须在本进程内执行，目录状态才能跨命令保持
                if segment.text == "cd" || segment.text.hasPrefix("cd ") {
                    let builtin = BuiltinInterpreter.execute(segment.text)
                    usedBuiltinCd = true
                    if !builtin.text.isEmpty {
                        outputLines.append(builtin.text)
                    }
                    lastExitCode = builtin.exitCode
                    pipedInput = nil
                    continue
                }

                // 重定向由应用执行（fork 不可用，无法依赖 shell 自己做）
                var stdinData = receivesPipeInput ? pipedInput : nil
                if let stdinPath = segment.stdinPath {
                    let resolved = resolvePath(stdinPath)
                    if let data = FileManager.default.contents(atPath: resolved) {
                        stdinData = data
                    } else {
                        outputLines.append("[TT] \(segment.text): 无法读取 \(stdinPath)")
                        lastExitCode = 1
                        pipedInput = nil
                        continue
                    }
                }

                let result = ProcessLauncher.spawnCapturing(
                    path: mkshPath,
                    arguments: ["-c", segment.text],
                    environment: environment,
                    stdinData: stdinData
                )
                if result.spawnErrno != 0 {
                    outputLines.append(failureRecord(path: mkshPath, spawnErrno: result.spawnErrno))
                    failedToSpawn = true
                    break
                }

                var text = result.output
                if let stdoutPath = segment.stdoutPath {
                    let resolved = resolvePath(stdoutPath)
                    if let written = writeRedirect(text, to: resolved, append: segment.stdoutAppend) {
                        outputLines.append(written)
                    } else {
                        outputLines.append("[TT] \(segment.text): 无法写入 \(stdoutPath)")
                        lastExitCode = 1
                        pipedInput = nil
                        continue
                    }
                    text = ""
                }

                let trimmedText = text.trimmingCharacters(in: .newlines)
                // 管道上游的输出只进管道，不上屏（与真实 shell 一致）；
                // 只有最终可见的那一段才显示。
                if !trimmedText.isEmpty && segment.separatorAfter != "|" {
                    outputLines.append(trimmedText)
                }
                lastExitCode = result.exitCode
                if result.exitCode > 128 {
                    outputLines.append("[TT] 诊断：命令「\(segment.text)」被信号 \(result.exitCode - 128) 终止。")
                }
                pipedInput = Data(result.output.utf8)
            }

            if failedToSpawn {
                let builtin = BuiltinInterpreter.execute(command)
                let builtinText = builtin.text.isEmpty ? "(命令没有输出)" : builtin.text
                let engine = "[TT] 执行引擎：内置解释器（mksh 启动失败；以下输出由应用内建解释器真实调用系统接口产生）"
                completion("\(outputLines.joined(separator: "\n"))\n\(engine)\n\(builtinText)\n[TT] 退出码：\(builtin.exitCode)")
                return
            }

            let engineLabel = usedBuiltinCd
                ? "[TT] 执行引擎：mksh + 内置 cd（目录状态由终端保持）"
                : "[TT] 执行引擎：mksh（应用内置 Shell）"
            let body = outputLines.isEmpty ? "(命令没有输出)" : outputLines.joined(separator: "\n")
            completion("\(engineLabel)\n\(body)\n[TT] 退出码：\(lastExitCode)")
        }
    }

    /// Full diagnostic record required when posix_spawn fails:
    /// target path, errno, uid/euid, cwd, existence and executability.
    private static func failureRecord(path: String, spawnErrno: Int32) -> String {
        var cwdBuffer = [CChar](repeating: 0, count: 4096)
        let cwd = getcwd(&cwdBuffer, cwdBuffer.count).map { _ in String(cString: cwdBuffer) } ?? "(无法获取)"
        let exists = FileManager.default.fileExists(atPath: path)
        let execCheck = access(path, X_OK)
        let execDesc = execCheck == 0 ? "是（access X_OK=0）" : "否（\(String(cString: strerror(errno)))）"
        return """
        [TT] Shell 启动失败记录：目标 \(path) -c <命令>
        [TT]   错误：\(String(cString: strerror(spawnErrno)))（errno \(spawnErrno)）
        [TT]   进程：uid=\(getuid()) euid=\(geteuid())；工作目录：\(cwd)
        [TT]   目标存在：\(exists ? "是" : "否")；路径可执行检查：\(execDesc)
        [TT]   说明：路径可执行 ≠ 有启动许可；此处由系统策略在进程创建阶段拒绝。
        """
    }
}

private struct BuiltinResult {
    let text: String
    let exitCode: Int32
}

/// In-app command interpreter used when the system shell cannot start.
/// Every command calls real system interfaces (filesystem, sysctl, statfs)
/// and reports real device data. It never fakes results.
private enum BuiltinInterpreter {
    static func execute(_ input: String) -> BuiltinResult {
        let tokens = tokenize(input)
        guard let name = tokens.first else {
            return BuiltinResult(text: "(空命令)", exitCode: 0)
        }
        let args = Array(tokens.dropFirst())
        switch name {
        case "pwd": return pwd()
        case "whoami": return whoami()
        case "date": return date(args)
        case "uname": return uname(args)
        case "ls": return ls(args)
        case "echo": return BuiltinResult(text: args.joined(separator: " "), exitCode: 0)
        case "cat": return cat(args)
        case "cd": return cd(args)
        case "df": return df(args)
        case "help": return help()
        default:
            return BuiltinResult(
                text: "[TT] 内置解释器没有命令「\(name)」（系统 /bin/sh 当前无法启动，外部命令不可用）。\n[TT] 输入 help 查看本引擎支持的命令。",
                exitCode: 127
            )
        }
    }

    // MARK: - 命令实现（全部走真实系统接口）

    private static func pwd() -> BuiltinResult {
        var buffer = [CChar](repeating: 0, count: 4096)
        if let cwd = getcwd(&buffer, buffer.count) {
            return BuiltinResult(text: String(cString: cwd), exitCode: 0)
        }
        return BuiltinResult(text: "pwd: \(String(cString: strerror(errno)))", exitCode: 1)
    }

    private static func whoami() -> BuiltinResult {
        let uid = getuid()
        let name: String
        switch uid {
        case 0: name = "root"
        case 501: name = "mobile"
        default: name = "uid\(uid)"
        }
        return BuiltinResult(text: name, exitCode: 0)
    }

    private static func date(_ args: [String]) -> BuiltinResult {
        guard args.isEmpty else {
            return BuiltinResult(text: "date: 内置解释器暂不支持参数（收到：\(args.joined(separator: " "))）", exitCode: 1)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss zzz yyyy"
        return BuiltinResult(text: formatter.string(from: Date()), exitCode: 0)
    }

    private static func uname(_ args: [String]) -> BuiltinResult {
        let sysname = sysctlString("kern.sysname")
        let nodename = sysctlString("kern.nodename")
        let release = sysctlString("kern.osrelease")
        let version = sysctlString("kern.version")
        let machine = sysctlString("hw.machine")
        if args.isEmpty {
            return BuiltinResult(text: sysname, exitCode: 0)
        }
        if args.count == 1 {
            switch args[0] {
            case "-a": return BuiltinResult(text: "\(sysname) \(nodename) \(release) \(version) \(machine)", exitCode: 0)
            case "-s": return BuiltinResult(text: sysname, exitCode: 0)
            case "-n": return BuiltinResult(text: nodename, exitCode: 0)
            case "-r": return BuiltinResult(text: release, exitCode: 0)
            case "-v": return BuiltinResult(text: version, exitCode: 0)
            case "-m": return BuiltinResult(text: machine, exitCode: 0)
            default: break
            }
        }
        return BuiltinResult(text: "uname: 不支持的参数 \(args.joined(separator: " "))（内置解释器支持 -a -n -s -r -v -m）", exitCode: 1)
    }

    private static func ls(_ args: [String]) -> BuiltinResult {
        var showHidden = false
        var pathArg: String?
        for arg in args {
            switch arg {
            case "-a", "-la", "-al":
                showHidden = true
            default:
                if arg.hasPrefix("-") {
                    return BuiltinResult(text: "ls: 内置解释器暂不支持选项 \(arg)（支持 -a）", exitCode: 1)
                }
                if pathArg == nil {
                    pathArg = arg
                } else {
                    return BuiltinResult(text: "ls: 内置解释器一次只接受一个路径", exitCode: 1)
                }
            }
        }
        let path = pathArg ?? FileManager.default.currentDirectoryPath
        var names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: path)
        } catch {
            return BuiltinResult(text: "ls: \(path): \(error.localizedDescription)", exitCode: 1)
        }
        if !showHidden {
            names = names.filter { !$0.hasPrefix(".") }
        }
        names.sort()
        guard !names.isEmpty else {
            return BuiltinResult(text: "", exitCode: 0)
        }
        var lines: [String] = []
        for name in names {
            let full = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
            lines.append(isDir.boolValue ? name + "/" : name)
        }
        return BuiltinResult(text: lines.joined(separator: "\n"), exitCode: 0)
    }

    private static func cat(_ args: [String]) -> BuiltinResult {
        guard !args.isEmpty else {
            return BuiltinResult(text: "cat: 需要文件名参数", exitCode: 1)
        }
        var chunks: [String] = []
        var exitCode: Int32 = 0
        for file in args {
            if let data = FileManager.default.contents(atPath: file) {
                if let text = String(data: data, encoding: .utf8) {
                    chunks.append(text)
                } else {
                    chunks.append("cat: \(file): 不是 UTF-8 文本")
                    exitCode = 1
                }
            } else {
                chunks.append("cat: \(file): \(String(cString: strerror(errno)))")
                exitCode = 1
            }
        }
        return BuiltinResult(text: chunks.joined(separator: "\n"), exitCode: exitCode)
    }

    /// Changes the terminal process working directory so it persists across
    /// commands (a real shell would lose it because every command is a new
    /// process; later mksh commands inherit the new cwd via posix_spawn).
    private static func cd(_ args: [String]) -> BuiltinResult {
        guard args.count <= 1 else {
            return BuiltinResult(text: "cd: too many arguments", exitCode: 1)
        }
        let target = args.first ?? ""
        if target.isEmpty {
            return BuiltinResult(text: "", exitCode: 0)
        }
        if target == "-" {
            return BuiltinResult(text: "cd: - 暂不支持（无上一个目录记录）", exitCode: 1)
        }
        var cwdBuffer = [CChar](repeating: 0, count: 4096)
        let current = getcwd(&cwdBuffer, cwdBuffer.count).map { _ in String(cString: cwdBuffer) } ?? "/"
        let resolved = target.hasPrefix("/") ? target : (current as NSString).appendingPathComponent(target)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue else {
            return BuiltinResult(text: "cd: \(target): No such file or directory", exitCode: 1)
        }
        guard FileManager.default.changeCurrentDirectoryPath(resolved) else {
            return BuiltinResult(text: "cd: \(target): Permission denied", exitCode: 1)
        }
        return BuiltinResult(text: "", exitCode: 0)
    }

    private static func df(_ args: [String]) -> BuiltinResult {
        let mountPoint = args.first ?? "/"
        var stats = statfs()
        guard statfs(mountPoint, &stats) == 0 else {
            return BuiltinResult(text: "df: \(mountPoint): \(String(cString: strerror(errno)))", exitCode: 1)
        }
        let mountedOn = withUnsafePointer(to: stats.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: stats.f_mntonname)) {
                String(cString: $0)
            }
        }
        let device = withUnsafePointer(to: stats.f_mntfromname) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: stats.f_mntfromname)) {
                String(cString: $0)
            }
        }
        let blockSize = UInt64(stats.f_bsize)
        let total = UInt64(stats.f_blocks) * blockSize
        let free = UInt64(stats.f_bfree) * blockSize
        let available = UInt64(stats.f_bavail) * blockSize
        let used = total - free
        let capacity = total > 0
            ? String(format: "%.0f%%", Double(total - available) / Double(total) * 100)
            : "-"
        let header = "Filesystem" + column("", 4) + column("Size", 7) + column("Used", 7) + column("Avail", 7) + column("Capacity", 9) + "Mounted on"
        let row = column(device, 14) + column(humanBytes(total), 7) + column(humanBytes(used), 7) + column(humanBytes(available), 7) + column(capacity, 9) + mountedOn
        return BuiltinResult(text: header + "\n" + row, exitCode: 0)
    }

    private static func help() -> BuiltinResult {
        return BuiltinResult(text: """
        [TT] 内置解释器支持的命令（均由应用真实调用系统接口执行）：
          pwd                 显示当前目录
          ls [-a] [路径]      列出目录内容（目录以 / 结尾）
          whoami              显示当前用户（uid 映射）
          uname [-a|-n|-s|-r|-v|-m]  显示系统信息（sysctl 真机数据）
          date                显示日期时间
          echo 内容           回显文本
          cat 文件...         显示文本文件内容
          cd [目录]          切换当前目录（终端进程保持，后续命令跟随）
          df [路径]           显示磁盘使用（statfs 真机数据）
          help / clear        本说明 / 清屏
        说明：管道、重定向、&&、外部程序由内置 mksh Shell 提供；
        本解释器仅在 mksh 无法启动时兜底（见启动自检结论）。
        """, exitCode: 0)
    }

    // MARK: - 工具函数

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "(未知)" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "(未知)" }
        return String(cString: buffer)
    }

    private static func humanBytes(_ bytes: UInt64) -> String {
        let units = ["B", "K", "M", "G", "T"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index == 0 {
            return String(format: "%.0f%@", value, units[index])
        }
        return String(format: "%.1f%@", value, units[index])
    }

    private static func column(_ text: String, _ width: Int) -> String {
        let paddedWidth = max(width, text.count)
        return text.padding(toLength: paddedWidth, withPad: " ", startingAt: 0)
    }

    private static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var hasCurrent = false
        for character in input {
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "'" || character == "\"" {
                quote = character
                hasCurrent = true
            } else if character == " " || character == "\t" {
                if hasCurrent {
                    tokens.append(current)
                    current = ""
                    hasCurrent = false
                }
            } else {
                current.append(character)
                hasCurrent = true
            }
        }
        if hasCurrent {
            tokens.append(current)
        }
        return tokens
    }
}

/// Startup self-check: process identity, path accessibility, three spawn probes
/// (/bin/sh, /usr/bin/true, container ttprobe) and a data-driven conclusion
/// about where the iOS launch limit actually lies.
private enum EnvironmentProbe {
    static func fullReport() -> String {
        var lines: [String] = ["[TT] ── 启动自检 ──"]
        lines.append("[TT] 进程：uid=\(getuid()) euid=\(geteuid())")
        var cwdBuffer = [CChar](repeating: 0, count: 4096)
        let cwd = getcwd(&cwdBuffer, cwdBuffer.count).map { _ in String(cString: cwdBuffer) } ?? "(无法获取)"
        lines.append("[TT] 工作目录：\(cwd)")
        lines.append("[TT] 签名与权限：\(signingInfoSummary())")
        lines.append(pathCheck("/bin/sh"))
        lines.append(pathCheck("/etc/passwd"))
        let mkshPath = (Bundle.main.bundlePath as NSString).appendingPathComponent("ttbin/mksh")
        let binPath = (Bundle.main.bundlePath as NSString).appendingPathComponent("ttbin")
        lines.append(pathCheck(mkshPath, display: "内置 Shell mksh"))
        lines.append("[TT] 嵌套二进制签名（mksh）：\(entitlementsSummary(ofBinaryAt: mkshPath))")
        let probePath = (Bundle.main.bundlePath as NSString).appendingPathComponent("ttprobe")
        lines.append(pathCheck(probePath, display: "容器内探针 ttprobe"))
        lines.append("[TT] 内置工具目录 ttbin/：\(ttbinInventory(binPath))")
        var forkIsBroken = false

        let shellEnvironment = ["PATH": "\(binPath):/usr/bin:/bin", "TERM": "dumb"]
        let binshResult = ProcessLauncher.spawnCapturing(path: "/bin/sh", arguments: ["-c", "exit 0"])
        lines.append("[TT] 启动探测① /bin/sh：\(describe(binshResult))")
        let mkshResult = ProcessLauncher.spawnCapturing(path: mkshPath, arguments: ["-c", "exit 0"], environment: shellEnvironment)
        lines.append("[TT] 启动探测② 内置 mksh：\(describe(mkshResult))")
        let probe = ProcessLauncher.spawnCapturing(path: probePath, arguments: ["ttprobe"])
        lines.append("[TT] 启动探测③ 容器内 ttprobe：\(describe(probe))")

        // 进程创建能力探针：定位 fork 在第几次调用崩溃（纯 fork 与 fork+exec 各测一轮）
        let forkPath = (Bundle.main.bundlePath as NSString).appendingPathComponent("ttbin/ttfork")
        if FileManager.default.isExecutableFile(atPath: forkPath) {
            let forkProbe = ProcessLauncher.spawnCapturing(path: forkPath, arguments: ["ttfork", probePath, "8"], environment: shellEnvironment)
            let forkText = forkProbe.output.trimmingCharacters(in: .newlines)
            if forkText.isEmpty {
                lines.append("[TT] fork 探针：无输出（退出码 \(forkProbe.exitCode)）")
            } else {
                lines.append("[TT] fork 探针：")
                lines.append(forkText)
            }
            forkIsBroken = forkText.contains("BROKEN:signal") || forkText.contains("BROKEN:fork")
        } else {
            lines.append("[TT] fork 探针：ttfork 未随包提供")
        }

        lines.append("[TT] 结论：\(conclusion(binsh: binshResult, mksh: mkshResult, probe: probe, forkBroken: forkIsBroken))")
        lines.append("[TT] ── 自检结束 ──")
        return lines.joined(separator: "\n")
    }

    private static func pathCheck(_ path: String, display: String? = nil) -> String {
        let label = display ?? path
        let exists = FileManager.default.fileExists(atPath: path)
        let readable = access(path, R_OK) == 0
        let executable = access(path, X_OK) == 0
        return "[TT] 路径检查：\(label) 存在=\(exists ? "是" : "否") 可读=\(readable ? "是" : "否") 可执行=\(executable ? "是" : "否")"
    }

    /// Inventory of the bundled ttbin/ directory. One line answers the question
    /// that mksh's "inaccessible or not found" cannot: is the binary actually in
    /// the bundle, executable, and carrying entitlements?
    /// Legend: `*` executable, `+` has no-sandbox, `!` not executable, `-ent` no entitlements.
    private static func ttbinInventory(_ path: String) -> String {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return "无法读取目录 \(path)"
        }
        guard !names.isEmpty else { return "(目录为空)" }
        var parts: [String] = []
        for name in names.sorted() {
            let full = (path as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full, isDirectory: &isDir) else {
                parts.append("\(name)=缺失")
                continue
            }
            if isDir.boolValue {
                parts.append("\(name)/")
                continue
            }
            var size = 0
            if let attributes = try? FileManager.default.attributesOfItem(atPath: full),
               let attributeSize = attributes[.size] as? NSNumber {
                size = attributeSize.intValue
            }
            let executable = access(full, X_OK) == 0
            let signed = entitlementsSummary(ofBinaryAt: full).contains("no-sandbox")
            // 大小始终显示，可执行性用前缀标记，避免"只有失败时才看得到大小"的信息不对称
            let mark = executable ? "*" : "!"
            let entMark = signed ? "+" : "-ent"
            parts.append("\(name)\(mark)\(size)B\(entMark)")
        }
        return parts.joined(separator: " ")
    }

    private static func describe(_ result: SpawnResult) -> String {
        if result.spawnErrno != 0 {
            return "失败 \(String(cString: strerror(result.spawnErrno)))（errno \(result.spawnErrno)）——进程从未创建"
        }
        let output = result.output.trimmingCharacters(in: .newlines)
        if output.isEmpty {
            return "成功（退出码 \(result.exitCode)）"
        }
        return "成功（退出码 \(result.exitCode)）：\(output.prefix(200))"
    }

    private static func conclusion(binsh: SpawnResult, mksh: SpawnResult, probe: SpawnResult, forkBroken: Bool) -> String {
        switch (mksh.spawnErrno == 0, binsh.spawnErrno == 0) {
        case (true, true):
            return "内置 mksh 与系统 /bin/sh 均可启动——命令由内置 mksh 执行。"
        case (true, false):
            if forkBroken {
                return "内置 mksh 可启动，系统 /bin/sh 不存在；本设备 fork() 不可用（探针确认 SIGBUS），因此管道、&& 与重定向由应用层拆分为单条命令逐段执行，每段仍由 mksh 真实执行。"
            }
            return "内置 mksh 可启动——命令由真实 Shell 执行；系统 /bin/sh 不存在或被拒。"
        case (false, true):
            return "系统 /bin/sh 可启动；内置 mksh 启动失败——命令由系统 Shell 执行。"
        case (false, false):
            return "内置 mksh 与系统 /bin/sh 均无法启动（进程创建受限）——命令由内置解释器执行（见 help）。"
        }
    }

    /// Reports the RUNNING app's entitlements by parsing the main binary's own
    /// code signature (SecCode APIs are unavailable on the iOS public SDK, so we
    /// read LC_CODE_SIGNATURE / superblob / entitlements XML directly).
    /// Answers "what permissions did TrollStore actually apply at install time".
    private static func signingInfoSummary() -> String {
        guard let exePath = Bundle.main.executablePath else {
            return "无法读取主二进制路径"
        }
        return entitlementsSummary(ofBinaryAt: exePath)
    }

    /// Parses entitlements out of any Mach-O's embedded code signature.
    private static func entitlementsSummary(ofBinaryAt path: String) -> String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count > 64 else {
            return "无法读取二进制"
        }
        func le32(_ o: Int) -> UInt32 {
            UInt32(data[o]) | UInt32(data[o + 1]) << 8 | UInt32(data[o + 2]) << 16 | UInt32(data[o + 3]) << 24
        }
        func be32(_ o: Int) -> UInt32 {
            UInt32(data[o]) << 24 | UInt32(data[o + 1]) << 16 | UInt32(data[o + 2]) << 8 | UInt32(data[o + 3])
        }
        // thin arm64 Mach-O: magic on disk = CF FA ED FE
        guard data[0] == 0xCF, data[1] == 0xFA, data[2] == 0xED, data[3] == 0xFE else {
            return "不是 thin arm64 Mach-O，跳过解析"
        }
        let ncmds = Int(le32(16))
        var offset = 32
        var csOffset = -1
        for _ in 0..<ncmds {
            guard offset + 8 <= data.count else { break }
            let cmd = le32(offset)
            let cmdSize = Int(le32(offset + 4))
            if cmd == 0x1d { csOffset = Int(le32(offset + 8)) } // LC_CODE_SIGNATURE
            offset += cmdSize
        }
        guard csOffset > 0, csOffset + 12 <= data.count else {
            return "未找到代码签名段（未签名？）"
        }
        guard be32(csOffset) == 0xFADE0CC0 else { return "代码签名段格式异常" } // superblob
        let count = Int(be32(csOffset + 8))
        for index in 0..<count {
            let slot = csOffset + 12 + index * 8
            guard slot + 8 <= data.count, be32(slot) == 5 else { continue } // CSSLOT_ENTITLEMENTS
            let blob = csOffset + Int(be32(slot + 4))
            guard blob + 8 <= data.count, be32(blob) == 0xFADE7171 else { continue }
            let length = Int(be32(blob + 4))
            guard length > 8, blob + 8 + length <= data.count else { continue }
            let xml = String(data: data.subdata(in: (blob + 8)..<(blob + length)), encoding: .utf8) ?? ""
            var names: [String] = []
            var search = xml.startIndex
            while let keyRange = xml.range(of: "<key>", range: search..<xml.endIndex) {
                let valueStart = keyRange.upperBound
                guard let endRange = xml.range(of: "</key>", range: valueStart..<xml.endIndex) else { break }
                names.append(String(xml[valueStart..<endRange.lowerBound]))
                search = endRange.upperBound
            }
            return names.isEmpty ? "entitlements 块为空" : names.sorted().joined(separator: ", ")
        }
        return "（无 entitlements）"
    }
}
