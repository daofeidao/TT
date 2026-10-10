import SwiftUI
import UIKit
import Darwin
import Combine

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

/// 一条命令的说明。手册里的数据写死在这里，方便校对文案。
struct CommandDoc: Identifiable {
    let id = UUID()
    let name: String
    let syntax: String
    let summary: String
    let category: String
}

enum CommandManual {
    /// 功能分区的展示顺序
    static let categoryOrder = ["文件与目录", "文本处理", "信息查询", "Shell 内建", "诊断探针"]

    static let docs: [CommandDoc] = [
        // —— 文件与目录 ——
        CommandDoc(name: "ls", syntax: "ls [-l] [-a] [路径]", summary: "列出目录内容，目录带 / 结尾", category: "文件与目录"),
        CommandDoc(name: "touch", syntax: "touch 文件...", summary: "创建空文件，或更新已有文件的修改时间", category: "文件与目录"),
        CommandDoc(name: "mkdir", syntax: "mkdir [-p] 目录...", summary: "创建目录，-p 会自动创建缺失的父目录", category: "文件与目录"),
        CommandDoc(name: "rm", syntax: "rm [-f] 文件... / rm -r [-f] 目录", summary: "删除文件；-r 递归删目录，-f 忽略不存在的路径", category: "文件与目录"),
        CommandDoc(name: "cp", syntax: "cp [-r] 源 目标", summary: "复制文件；目标为已存在目录时复制到其内部", category: "文件与目录"),
        CommandDoc(name: "mv", syntax: "mv 源 目标", summary: "改名或移动；跨设备时自动退化为复制后删除", category: "文件与目录"),

        // —— 文本处理 ——
        CommandDoc(name: "cat", syntax: "cat 文件...", summary: "输出文件全部内容，也可接管道输入", category: "文本处理"),
        CommandDoc(name: "head", syntax: "head [-n 数量] [文件]", summary: "取开头若干行", category: "文本处理"),
        CommandDoc(name: "tail", syntax: "tail [-n 数量] [文件]", summary: "取结尾若干行", category: "文本处理"),
        CommandDoc(name: "wc", syntax: "wc [-l] [-w] [-c] [文件]", summary: "统计行数、词数、字节数", category: "文本处理"),
        CommandDoc(name: "grep", syntax: "grep [-i] [-v] [-n] 模式 [文件]", summary: "按行筛选，-i 忽略大小写，-v 反选", category: "文本处理"),
        CommandDoc(name: "sort", syntax: "sort [-n] [-r] [-u] [文件]", summary: "排序；-n 按数值，-r 倒序，-u 去重", category: "文本处理"),
        CommandDoc(name: "uniq", syntax: "uniq [-c] [文件]", summary: "去掉相邻重复行，-c 在行首显示出现次数", category: "文本处理"),
        CommandDoc(name: "cut", syntax: "cut -d 分隔符 -f 列表 [-c 列表]", summary: "按分隔符取列或按位置取字符", category: "文本处理"),
        CommandDoc(name: "tr", syntax: "tr [-d] 字符集1 [字符集2]", summary: "字符映射或删除，支持 a-z 这样的区间写法", category: "文本处理"),

        // —— 信息查询 ——
        CommandDoc(name: "df", syntax: "df [-h]", summary: "查看磁盘使用量", category: "信息查询"),
        CommandDoc(name: "du", syntax: "du [-s] [-h] [路径]", summary: "统计目录占用空间", category: "信息查询"),
        CommandDoc(name: "stat", syntax: "stat 文件...", summary: "查看文件大小、权限、时间等元信息", category: "信息查询"),
        CommandDoc(name: "find", syntax: "find [路径] [-name 模式] [-type f|d]", summary: "递归查找，-name 匹配名字，-type 限文件或目录", category: "信息查询"),
        CommandDoc(name: "date", syntax: "date", summary: "当前日期时间", category: "信息查询"),
        CommandDoc(name: "whoami", syntax: "whoami", summary: "当前用户身份", category: "信息查询"),
        CommandDoc(name: "uname", syntax: "uname [-a]", summary: "系统信息", category: "信息查询"),

        // —— Shell 内建（由内置 mksh 提供）——
        CommandDoc(name: "echo", syntax: "echo 文本", summary: "输出文本；配合重定向可写文件", category: "Shell 内建"),
        CommandDoc(name: "pwd", syntax: "pwd", summary: "显示当前目录", category: "Shell 内建"),
        CommandDoc(name: "cd", syntax: "cd [目录]", summary: "切换目录，由 TT 在主进程内保持", category: "Shell 内建"),
        CommandDoc(name: "true", syntax: "true", summary: "返回 0，常用于 && 分支", category: "Shell 内建"),
        CommandDoc(name: "false", syntax: "false", summary: "返回 1，常用于 || 分支", category: "Shell 内建"),
        CommandDoc(name: "test", syntax: "test 条件", summary: "条件判断，配合 [ ] 使用", category: "Shell 内建"),
        CommandDoc(name: "sleep", syntax: "sleep 秒", summary: "等待若干秒", category: "Shell 内建"),
        CommandDoc(name: "clear", syntax: "clear", summary: "由 TT 截获，清空终端显示", category: "Shell 内建"),

        // —— 诊断探针 ——
        CommandDoc(name: "ttfork", syntax: "ttfork", summary: "探测本机 fork 是否可用（三阶段实测）", category: "诊断探针"),
        CommandDoc(name: "ttprobe", syntax: "ttprobe", summary: "探测容器与沙盒环境，产出启动自检报告", category: "诊断探针")
    ]

    static func sorted(byAlphabet: Bool, keyword: String) -> [CommandDoc] {
        let filtered = keyword.isEmpty
            ? docs
            : docs.filter {
                $0.name.localizedCaseInsensitiveContains(keyword)
                    || $0.summary.localizedCaseInsensitiveContains(keyword)
                    || $0.syntax.localizedCaseInsensitiveContains(keyword)
            }
        if byAlphabet {
            return filtered.sorted { $0.name < $1.name }
        }
        return filtered.sorted { a, b in
            let ia = categoryOrder.firstIndex(of: a.category) ?? Int.max
            let ib = categoryOrder.firstIndex(of: b.category) ?? Int.max
            if ia != ib { return ia < ib }
            return a.name < b.name
        }
    }

    static func groups(byAlphabet: Bool, keyword: String) -> [(key: String, value: [CommandDoc])] {
        let list = sorted(byAlphabet: byAlphabet, keyword: keyword)
        guard !byAlphabet else { return list.isEmpty ? [] : [("按字母顺序", list)] }
        var buckets: [(String, [CommandDoc])] = []
        for category in categoryOrder {
            let items = list.filter { $0.category == category }
            if !items.isEmpty { buckets.append((category, items)) }
        }
        return buckets
    }
}

/// 高危命令识别：命中就**直接拦截，不执行**。
enum DangerGuard {
    struct Hit {
        let reason: String
    }

    /// 规则按"是否不可逆 / 是否影响整个系统"来定；刻意不拦 `rm -rf /tmp/ttd`
    /// 这类日常操作，否则测试清单会被整片挡下来。
    private static let rules: [(test: (String) -> Bool, reason: String)] = [
        (test: { contains($0, "mkfs") || contains($0, "newfs") },
         reason: "格式化文件系统，会清空整个分区且不可恢复"),
        (test: { c in
            let d = c.contains("diskutil")
            return d && (c.contains("erase") || c.contains("reformat") || c.contains("partitiondisk") || c.contains("secureerase"))
         },
         reason: "diskutil 擦除或重分区，会彻底销毁磁盘数据"),
        (test: { c in c.contains("dd ") && c.contains("of=/dev/") },
         reason: "dd 直接写入块设备，可能覆盖整个磁盘分区"),
        (test: { c in
            let compact = c.replacingOccurrences(of: " ", with: "")
            return compact.contains(">/dev/rdisk") || compact.contains(">/dev/disk")
         },
         reason: "重定向到块设备等于直接覆写磁盘原始数据"),
        (test: { c in rmTargets(c).contains("/") || rmTargets(c).contains("/*") || rmTargets(c).contains("~") || rmTargets(c).contains("$HOME") },
         reason: "删除根目录或整个用户目录，系统将无法启动"),
        (test: { c in rmTargets(c).contains("*") },
         reason: "使用通配符递归删除，命中范围不可预估"),
        (test: { c in rmRecursive(c) && rmTargets(c).contains(where: { criticalPath($0) }) },
         reason: "递归强制删除系统关键目录"),
        (test: { c in
            let compact = c.replacingOccurrences(of: " ", with: "")
            return compact.contains("chmod-R777/") || (compact.contains("chown-R") && compact.hasSuffix("/"))
         },
         reason: "递归修改根目录权限或属主"),
        (test: { c in c.contains("killall") || c.contains("kill -9 -1") },
         reason: "批量结束系统进程，可能导致系统不稳定"),
        (test: { c in c.contains(":(){") && c.contains("&};") },
         reason: "fork 炸弹，会瞬间耗尽进程与 CPU")
    ]

    static func evaluate(_ command: String) -> Hit? {
        let lowered = command.lowercased()
        for rule in rules where rule.test(lowered) {
            return Hit(reason: rule.reason)
        }
        return nil
    }

    static var ruleCount: Int { rules.count }

    // —— 下面几个小工具只服务于上面的规则，让规则本身读起来像一句话 ——
    private static func contains(_ command: String, _ token: String) -> Bool {
        command.contains(token)
    }

    /// 取 rm 后面的操作对象（已小写）
    private static func rmTargets(_ command: String) -> [String] {
        guard let range = command.range(of: "rm ") else { return [] }
        return command[range.upperBound...]
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private static func rmRecursive(_ command: String) -> Bool {
        command.contains("rm -rf") || command.contains("rm -fr") || command.contains("rm -r -f")
    }

    private static func criticalPath(_ path: String) -> Bool {
        let critical = ["/etc", "/var", "/usr", "/bin", "/sbin", "/lib", "/private", "/system", "/applications"]
        return critical.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}

/// 输入框控制器：扩展键需要直接操作 `UITextField`（在光标处插入、删除），
/// SwiftUI 侧通过它下发指令。
final class CommandInputController: ObservableObject {
    weak var field: UITextField?

    /// 在当前光标位置插入文本，并把光标推到插入内容之后
    func insert(_ text: String) {
        guard let field = field else { return }
        let current = field.text ?? ""
        let range = field.selectedRange
        // 防御：SwiftUI 回写可能让 selectedRange 越界
        let location = min(max(0, range.location), current.utf16.count)
        let length = min(max(0, range.length), current.utf16.count - location)
        let target = NSRange(location: location, length: length)

        let mutable = NSMutableString(string: current)
        mutable.replaceCharacters(in: target, with: text)
        field.text = mutable as String
        let after = location + (text as NSString).length
        field.selectedRange = NSRange(location: after, length: 0)
        field.sendActions(for: .editingChanged)
    }

    /// 退格：有选中区间就删区间，否则删光标前一个完整字素
    func backspace() {
        guard let field = field else { return }
        let current = field.text ?? ""
        guard !current.isEmpty else { return }
        let range = field.selectedRange
        let location = min(max(0, range.location), current.utf16.count)
        let length = min(max(0, range.length), current.utf16.count - location)

        let deleteRange: NSRange
        if length > 0 {
            deleteRange = NSRange(location: location, length: length)
        } else {
            guard location > 0 else { return }
            // 取光标前一个位置所在的完整字素簇：中文、emoji 都整体删，不会留下半个
            let ns = current as NSString
            let cluster = ns.rangeOfComposedCharacterSequence(at: location - 1)
            let start = min(cluster.location, location)
            deleteRange = NSRange(location: start, length: location - start)
        }

        let mutable = NSMutableString(string: current)
        mutable.replaceCharacters(in: deleteRange, with: "")
        field.text = mutable as String
        field.selectedRange = NSRange(location: deleteRange.location, length: 0)
        field.sendActions(for: .editingChanged)
    }
}

/// 命令输入框。
///
/// 用 `UITextField` 而不是 SwiftUI 的 `TextField`，因为只有拿到原生对象
/// 才能设置 `textInputMode`（切英文输入法）以及在光标处插入扩展键位的字符。
struct CommandInputField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isEditing: Bool
    var prefersEnglishKeyboard: Bool
    var placeholder: String
    var onSubmit: () -> Void
    var controller: CommandInputController?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.delegate = context.coordinator
        field.font = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        field.textColor = .white
        field.tintColor = .green
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.smartInsertDeleteType = .no
        field.returnKeyType = .send
        field.clearButtonMode = .whileEditing
        field.attributedPlaceholder = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: UIColor(white: 0.55, alpha: 1)])
        field.accessibilityIdentifier = "tt.command.input"
        field.addTarget(context.coordinator,
                        action: #selector(Coordinator.editingChanged(_:)),
                        for: .editingChanged)
        controller?.field = field
        return field
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        controller?.field = uiView
        if uiView.text != text { uiView.text = text }
        context.coordinator.parent = self

        if isEditing, !uiView.isFirstResponder {
            // 必须在 becomeFirstResponder **之前**设好，否则系统已按旧模式弹出键盘
            //
            // 注意：Swift 的 UIKit overlay 把 UITextInputTraits.textInputMode 暴露成
            // 只读属性，直接赋值编译不过（ObjC 侧本身是可写的），所以走 KVC。
            if prefersEnglishKeyboard, let mode = Self.englishInputMode() {
                uiView.setValue(mode, forKey: "textInputMode")
            }
            uiView.becomeFirstResponder()
        } else if !isEditing, uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    /// 取英文输入模式。系统允许同时装多套键盘时，`activeInputModes` 才有内容；
    /// 拿不到就返回 nil，保持系统当前模式，不做强制。
    static func englishInputMode() -> UITextInputMode? {
        let modes = UITextInputMode.activeInputModes
        return modes.first { $0.primaryLanguage == "en-US" }
            ?? modes.first { $0.primaryLanguage?.hasPrefix("en") == true }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: CommandInputField

        init(_ parent: CommandInputField) {
            self.parent = parent
        }

        @objc func editingChanged(_ field: UITextField) {
            parent.text = field.text ?? ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onSubmit()
            return false
        }

        // 手动点输入框时也要把状态同步回来，否则补全条会在用户主动输入时不出现
        func textFieldDidBeginEditing(_ textField: UITextField) {
            if !parent.isEditing { parent.isEditing = true }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            if parent.isEditing { parent.isEditing = false }
        }
    }
}

/// 移动光标（扩展键的左右箭头）
    func moveCursor(by offset: Int) {
        guard let field = field else { return }
        let length = (field.text ?? "").utf16.count
        let range = field.selectedRange
        let location = min(max(0, range.location + offset), length)
        field.selectedRange = NSRange(location: location, length: 0)
    }

    func clear() {
        guard let field = field else { return }
        field.text = ""
        field.sendActions(for: .editingChanged)
    }

    /// 在已装的多套键盘间轮换（扩展键的 `A/文`）。
    /// 换语言必须 resign 再 become，系统才会按新模式重建键盘。
    func cycleInputLanguage() -> String? {
        guard let field = field else { return nil }
        let modes = UITextInputMode.activeInputModes
        guard modes.count > 1 else { return nil }
        let current = field.textInputMode
        let index = modes.firstIndex { $0 === current } ?? -1
        let next = modes[(index + 1) % modes.count]
        field.setValue(next, forKey: "textInputMode")
        field.resignFirstResponder()
        field.becomeFirstResponder()
        return next.primaryLanguage
    }
}

/// 扩展键盘的一条按键
private struct KeyCap: Identifiable {
    let id = UUID()
    let label: String
    let width: CGFloat
    let insert: String
    let action: (() -> Void)?

    init(_ label: String, width: CGFloat = 46, insert: String) {
        self.label = label
        self.width = width
        self.insert = insert
        self.action = nil
    }

    init(_ label: String, width: CGFloat = 46, action: @escaping () -> Void) {
        self.label = label
        self.width = width
        self.insert = ""
        self.action = action
    }
}

/// 终端扩展键盘：默认收起，点输入框左边的 `›` 展开。
///
/// 键位不照抄参考图，而是按终端里真正高频的动作排：
/// 第一行是「移动与控制」，第二行是「管道与重定向」——
/// 这两类恰好是手机软键盘最难打、而敲 shell 又最常用的。
struct ExtendedKeyBar: View {
    let showSymbols: Bool
    let showFunctionKeys: Bool
    let onInsert: (String) -> Void
    let onBackspace: () -> Void
    let onCursor: (Int) -> Void
    let onInterrupt: () -> Void
    let onClear: () -> Void
    let onComplete: () -> Void
    let onHistory: (Int) -> Void
    let onToggleLanguage: () -> Void
    let onToggleSymbols: () -> Void
    let onToggleFunctionKeys: () -> Void
    let onDismiss: () -> Void

    private var controlRow: [KeyCap] {
        [
            KeyCap("esc", action: onClear),
            KeyCap("tab", width: 50, action: onComplete),
            KeyCap("^C", width: 50, action: onInterrupt),
            KeyCap("⌫", width: 50, action: onBackspace),
            KeyCap("←", width: 44, action: { onCursor(-1) }),
            KeyCap("→", width: 44, action: { onCursor(1) }),
            KeyCap("↑", width: 44, action: { onHistory(-1) }),
            KeyCap("↓", width: 44, action: { onHistory(1) }),
            KeyCap("A/文", width: 58, action: onToggleLanguage)
        ]
    }

    /// 管道与重定向：手机软键盘上最难够到的就是这几个
    private var shellRow: [KeyCap] {
        ["|", ">", ">>", "<", "2>", "&", ";", "~", "/", "-", "_", ".", "=", "*"]
            .map { KeyCap($0, insert: $0) }
    }

    private var symbolRow: [KeyCap] {
        ["(", ")", "[", "]", "{", "}", "\"", "'", ":", ",", "\\", "`", "$", "^", "%", "#", "@", "!", "?", "+"]
            .map { KeyCap($0, insert: $0) }
    }

    private var functionRow: [KeyCap] {
        (1...12).map { KeyCap("F\($0)", width: 42, insert: "") }
    }

    var body: some View {
        VStack(spacing: 5) {
            row(controlRow)
            row(shellRow)
            if showSymbols { row(symbolRow) }
            if showFunctionKeys { row(functionRow) }
            HStack(spacing: 6) {
                toggleChip("符号", active: showSymbols, action: onToggleSymbols)
                toggleChip("F 键", active: showFunctionKeys, action: onToggleFunctionKeys)
                Spacer(minLength: 8)
                Button(action: onDismiss) {
                    Text("收起键盘")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(red: 0.22, green: 0.23, blue: 0.27), in: Capsule())
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
        }
        .padding(.vertical, 7)
        .background(Color(red: 0.13, green: 0.14, blue: 0.16))
    }

    private func row(_ keys: [KeyCap]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(keys) { key in
                    Button {
                        if let action = key.action {
                            action()
                        } else if !key.insert.isEmpty {
                            onInsert(key.insert)
                        }
                    } label: {
                        Text(key.label)
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(width: key.width, height: 34)
                            .background(Color(red: 0.24, green: 0.25, blue: 0.29),
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
        }
    }

    private func toggleChip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(active ? Color.green.opacity(0.55) : Color(red: 0.22, green: 0.23, blue: 0.27),
                            in: Capsule())
                .foregroundColor(.white)
        }
        .buttonStyle(.plain)
    }
}

/// 「关于 TT」里的一行键值
private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .foregroundColor(.primary)
                .multilineTextAlignment(.trailing)
        }
        .font(.system(.subheadline, design: .monospaced))
    }
}

/// 命令手册：可按字母或按功能分区浏览，支持搜索
struct CommandManualSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var byAlphabet = false
    @State private var keyword = ""

    var body: some View {
        NavigationView {
            List {
                Section {
                    Picker("排序方式", selection: $byAlphabet) {
                        Text("按功能分区").tag(false)
                        Text("按字母顺序").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                ForEach(CommandManual.groups(byAlphabet: byAlphabet, keyword: keyword), id: \.key) { group in
                    Section(group.key) {
                        ForEach(group.value) { doc in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(doc.name)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(.green)
                                Text(doc.syntax)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                                Text(doc.summary)
                                    .font(.caption)
                                    .foregroundColor(.primary.opacity(0.8))
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .navigationTitle("命令手册")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $keyword, prompt: "搜命令名或用途")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// 高危命令拦截面板：只说明为什么拦，不提供任何放行入口
struct DangerBlockedSheet: View {
    let command: String
    let reason: String
    let onClose: () -> Void

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: "hand.raised.fill")
                        .foregroundColor(Color(red: 0.90, green: 0.36, blue: 0.36))
                    Text("命令已被拦截")
                        .font(.headline)
                        .foregroundColor(Color(red: 0.96, green: 0.42, blue: 0.42))
                }

                Text(reason)
                    .font(.callout)
                    .foregroundColor(Color(red: 0.96, green: 0.55, blue: 0.55))

                Text(command)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(red: 0.30, green: 0.08, blue: 0.08), in: RoundedRectangle(cornerRadius: 8))

                Text("这条命令不会被执行，本终端也不提供绕过入口。\n如果你确认确实需要它，请联系作者商量。")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                Spacer()
            }
            .padding(18)
            .background(Color(red: 0.11, green: 0.05, blue: 0.05))
            .navigationTitle("高危命令拦截")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("知道了", action: onClose)
                }
            }
        }
        .interactiveDismissDisabled()
        .preferredColorScheme(.dark)
    }
}

/// 清单条目的编辑/新增弹窗。两条路径共用一套表单。
struct ChecklistEditorSheet: View {
    /// 必须原样带回：checklistUpsert 按 id 匹配。
    /// 漏掉它会把"编辑"变成"追加一条新的"，原条目纹丝不动。
    let itemID: UUID
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
        self.itemID = item.id
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        _group = State(initialValue: item.group)
        _command = State(initialValue: item.command)
        _expect = State(initialValue: item.expect)
        _isCustom = State(initialValue: item.isCustom)
    }

    /// 组装保存用的条目：字段取表单，id 始终沿用被编辑的那一条
    private func makeItem() -> ChecklistItem {
        ChecklistItem(id: itemID,
                     group: group.trimmingCharacters(in: .whitespacesAndNewlines),
                     command: command.trimmingCharacters(in: .whitespacesAndNewlines),
                     expect: expect,
                     isCustom: isCustom || isNew)
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
                    Button("保存") { onSave(makeItem()) }
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
    // 自检报告专用：标签名抬亮、取值压暗、分隔标题更亮。
    // 报告有四十多行，原来整片同一个暗紫色，长标题和短取值糊在一起分不清主次。
    static let diagnosticLabel = UIColor(red: 0.886, green: 0.886, blue: 0.906, alpha: 1) // #E2E2E7 灰白
    static let diagnosticTitle = UIColor(red: 0.749, green: 0.831, blue: 0.867, alpha: 1)  // #BFD4DD 淡蓝灰
    static let diagnosticBody = UIColor(red: 0.451, green: 0.443, blue: 0.510, alpha: 1)  // #737182 更暗的取值

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
        // 自检行做行内两段着色：标签名亮、取值暗，一眼分得开
        if kind == .diagnostic {
            appendDiagnostic(text, to: result, font: font)
            return
        }
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

    /// 自检行的着色规则：
    /// - `── 启动自检 ──` 这类分隔标题 → 最亮的淡蓝灰
    /// - `[TT] 进程：uid=0` → 标签部分灰白，取值部分压暗
    /// - 无 `[TT]` 前缀的裸输出（fork 探针原文）→ 整体压暗
    private static func appendDiagnostic(_ text: String, to result: NSMutableAttributedString, font: UIFont) {
        func put(_ part: String, _ color: UIColor, bold: Bool = false) {
            guard !part.isEmpty else { return }
            var attributes = baseAttributes(font: font, color: color)
            if bold {
                let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) ?? font.fontDescriptor
                attributes[.font] = UIFont(descriptor: descriptor, size: font.pointSize)
            }
            result.append(NSAttributedString(string: part, attributes: attributes))
        }

        if text.contains("──") {
            put(text, TerminalPalette.diagnosticTitle, bold: true)
            return
        }
        guard text.hasPrefix("[TT]") else {
            put(text, TerminalPalette.diagnosticBody)
            return
        }
        // 标签取到第一个全角冒号为止（含冒号），其余算取值
        if let colon = text.range(of: "：") {
            put(String(text[..<colon.upperBound]), TerminalPalette.diagnosticLabel)
            put(String(text[colon.upperBound...]), TerminalPalette.diagnosticBody)
        } else {
            put(text, TerminalPalette.diagnosticLabel)
        }
    }
}

struct ContentView: View {
    @State private var command = ""
    /// 结构化终端记录：每一行都带语义类别，渲染时才上色。
    /// 改为结构化是为了"按来源着色"——TT 自己的消息和程序输出天然可分。
    @State private var transcript: [TranscriptSegment] = TranscriptClassifier.classify("""
    TT 终端 · \(ttAppVersion)
    命令由应用内置 mksh Shell 真实执行（系统不含 /bin/sh）；启动失败时自动降级内置解释器。
    """, fallback: .banner)
    @State private var history: [String] = []
    @State private var showHistory = false
    @State private var showChecklist = false
    @State private var checklist: [ChecklistItem] = ChecklistStore.load()
    @State private var checklistFilter: String = "全部"
    /// 用**数组下标**定位被编辑的条目，而不是靠 id 查找。
    /// 之前按 id 匹配一旦失配就会走 append 分支，"编辑"变成"再新增一条"，
    /// 原条目留在原地——这正是真机反馈的 bug。直接按下标覆盖，从结构上杜绝重复。
    @State private var editingIndex: Int?
    @State private var newItemDraft: ChecklistItem?
    @State private var diagnosticReport = ""
    @State private var showDiagnostics = false
    @State private var showManual = false
    @State private var pendingDanger: DangerGuard.Hit?
    @State private var pendingDangerCommand = ""
    @State private var isExecuting = false
    /// 输入框是否处于编辑态（键盘弹着）。
    /// 输入框是 `UITextField`，焦点变化由 `textFieldDidBeginEditing` 回报，
    /// 不再走 SwiftUI 的 @FocusState——那个只在挂了 `.focused()` 的视图上才有意义。
    @State private var commandInputFocused = false
    /// 只在"自检跑完自动弹键盘"这一次要求英文输入，
    /// 之后用户想切中文输入法随时能切，不做强制。
    @State private var wantsEnglishKeyboard = false
    /// 扩展键盘开关。默认收起，点输入框左边的 `›` 展开。
    @State private var showKeyBar = false
    @State private var showSymbolRows = false
    @State private var showFunctionKeys = false
    /// ↑↓ 翻历史时的游标；nil 表示当前不在翻历史
    @State private var historyCursor: Int?
    @StateObject private var inputController = CommandInputController()
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

                if !diagnosticReport.isEmpty {
                    Button {
                        showDiagnostics = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 16, weight: .medium))
                    }
                    .accessibilityLabel("关于 TT")
                    .accessibilityIdentifier("tt.about")
                }

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
                    scrollTranscript(proxy, animated: false)
                }
                // 键盘弹起会顶掉底部一屏，但 ScrollView 不会自己补滚，
                // 于是最后一行被压在键盘后面看不见。收起键盘时布局会自己回弹，
                // 所以平时只感知"键盘出现"这一侧。
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
                    scrollTranscript(proxy, animated: true, afterKeyboard: note)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                    scrollTranscript(proxy, animated: true, afterKeyboard: note)
                }
            }

            // 补全条：只在编辑中、且正停在命令名那一段时出现
            if commandInputFocused, !commandSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(commandSuggestions) { doc in
                            Button {
                                applySuggestion(doc)
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(doc.name)
                                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    Text(doc.syntax)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(
                                    currentTokenMatches(doc)
                                        ? Color.green.opacity(0.30)
                                        : Color(red: 0.16, green: 0.17, blue: 0.20),
                                    in: RoundedRectangle(cornerRadius: 7))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7)
                                        .stroke(currentTokenMatches(doc)
                                                ? Color.green.opacity(0.7)
                                                : Color.clear,
                                              lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                }
                .background(Color(red: 0.10, green: 0.11, blue: 0.13))
            }

            if showKeyBar {
                ExtendedKeyBar(showSymbols: showSymbolRows,
                               showFunctionKeys: showFunctionKeys,
                               onInsert: { inputController.insert($0) },
                               onBackspace: { inputController.backspace() },
                               onCursor: { inputController.moveCursor(by: $0) },
                               onInterrupt: interruptRunningCommand,
                               onClear: { inputController.clear() },
                               onComplete: completeFromKeyBar,
                               onHistory: stepHistory,
                               onToggleLanguage: cycleInputLanguage,
                               onToggleSymbols: { showSymbolRows.toggle() },
                               onToggleFunctionKeys: { showFunctionKeys.toggle() },
                               onDismiss: { withAnimation(.easeOut(duration: 0.15)) { showKeyBar = false } })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 8) {
                // `›` 兼作扩展键盘开关：点按区域做到 44×44，小屏也点得准
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showKeyBar.toggle() }
                    if showKeyBar { commandInputFocused = true }
                } label: {
                    Text("›")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(showKeyBar ? Color.black : Color.green)
                        .frame(width: 44, height: 44)
                        .background(showKeyBar ? Color.green : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showKeyBar ? "收起扩展键盘" : "展开扩展键盘")
                .accessibilityIdentifier("tt.keybar.toggle")

                CommandInputField(text: $command,
                                  isEditing: $commandInputFocused,
                                  prefersEnglishKeyboard: wantsEnglishKeyboard,
                                  placeholder: "输入命令，例如 pwd、ls、date",
                                  onSubmit: submitCommand,
                                  controller: inputController)
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
        .sheet(isPresented: $showManual) {
            CommandManualSheet()
        }
        .sheet(isPresented: Binding(
            get: { pendingDanger != nil },
            set: { if !$0 { pendingDanger = nil; pendingDangerCommand = "" } }
        )) {
            if let hit = pendingDanger {
                DangerBlockedSheet(command: pendingDangerCommand,
                                   reason: hit.reason,
                                   onClose: {
                                       pendingDanger = nil
                                       pendingDangerCommand = ""
                                       command = ""
                                   })
            }
        }
        .sheet(isPresented: $showDiagnostics) {
            NavigationView {
                List {
                    Section("版本") {
                        InfoRow(label: "TT 终端", value: ttAppVersion)
                        InfoRow(label: "包标识", value: Bundle.main.bundleIdentifier ?? "—")
                    }
                    Section("命令") {
                        InfoRow(label: "内置工具", value: "\(CommandManual.docs.count) 条")
                        InfoRow(label: "Shell", value: "内置 mksh")
                        InfoRow(label: "高危命令拦截", value: "已启用 · \(DangerGuard.ruleCount) 条规则")
                    }
                    Section("运行环境") {
                        InfoRow(label: "系统", value: UIDevice.current.systemName + " " + UIDevice.current.systemVersion)
                        InfoRow(label: "设备", value: UIDevice.current.model)
                        InfoRow(label: "清单条数", value: "\(checklist.count) 条")
                    }
                    Section {
                        NavigationLink {
                            ScrollView {
                                Text(diagnosticReport)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(Color(red: 0.62, green: 0.62, blue: 0.68))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(14)
                            }
                            .background(Color.black)
                            .navigationTitle("启动自检报告")
                            .navigationBarTitleDisplayMode(.inline)
                        } label: {
                            HStack {
                                Text("启动自检报告")
                                Spacer()
                                Text("\(diagnosticReport.split(separator: "\n", omittingEmptySubsequences: false).count) 行")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .navigationTitle("关于 TT")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("关闭") { showDiagnostics = false }
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
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
                        Text("点一条即执行；向左滑可选「编辑」或「删除」。改动会自动存本机。")
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
                                // 迭代 checklist 的**真实下标**，编辑时才能精确定位到同一条
                                ForEach(checklist.indices.filter { checklist[$0].group == group }, id: \.self) { index in
                                    let item = checklist[index]
                                    Button {
                                    showChecklist = false
                                    // 等面板收起再执行，避免和 sheet 转场动画抢状态
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        // 清单里的命令同样走高危拦截，不能绕过
                                        if let hit = DangerGuard.evaluate(item.command) {
                                            pendingDangerCommand = item.command
                                            pendingDanger = hit
                                        } else {
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
                                            }
                                            Text("期望：\(item.expect)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        .padding(.vertical, 2)
                                    }
                                    // 左滑露出编辑与删除；关掉整滑删除，避免手滑把整条清掉
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) {
                                            checklistDelete(item)
                                        } label: {
                                            Label("删除", systemImage: "trash")
                                        }
                                        Button {
                                            editingIndex = index
                                        } label: {
                                            Label("编辑", systemImage: "pencil")
                                        }
                                        .tint(Color(red: 0.30, green: 0.52, blue: 0.86))
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
                                showManual = true
                            } label: {
                                Label("查看全部命令", systemImage: "book")
                            }
                            Divider()
                            Button {
                                checklistRestoreDefaults()
                            } label: {
                                Label("恢复默认清单", systemImage: "arrow.counterclockwise")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                    // 右上角只留关闭。编辑和删除都收进左滑里，不再需要「编辑/完成」两个模式按钮。
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("关闭") { showChecklist = false }
                    }
                }
            }
            .preferredColorScheme(.dark)
            // 编辑弹窗挂在清单面板内部：
            // 若挂在 ContentView 上，清单 sheet 仍在前台时再 present 会被系统忽略。
            .sheet(isPresented: Binding(
                get: { editingIndex != nil },
                set: { if !$0 { editingIndex = nil } }
            )) {
                if let index = editingIndex, checklist.indices.contains(index) {
                    ChecklistEditorSheet(item: checklist[index],
                                         isNew: false,
                                         onSave: { updated in
                                             checklistUpdate(at: index, with: updated)
                                             editingIndex = nil
                                         },
                                         onDelete: {
                                             checklistDelete(checklist[index])
                                             editingIndex = nil
                                         },
                                         onCancel: { editingIndex = nil })
                }
            }
            .sheet(item: $newItemDraft) { item in
                ChecklistEditorSheet(item: item,
                                     isNew: true,
                                     onSave: { updated in
                                         checklistAdd(updated)
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
        historyCursor = nil
        // 高危命令直接拦下，不提供任何放行入口
        if let hit = DangerGuard.evaluate(text) {
            pendingDangerCommand = text
            pendingDanger = hit
            return
        }
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
                // 自检报告很长，默认塞进终端会把首屏全占满、真正的提示挤到看不见。
                // 这里只留一行结论，完整报告存起来给顶栏的 ⓘ 按钮看；
                // 需要排查时随时能翻，也不会妨碍往下拉回看终端。
                self.diagnosticReport = report
                let lineCount = report.split(separator: "\n", omittingEmptySubsequences: false).count
                self.transcript.append(TranscriptSegment(kind: .banner, text: ""))
                self.transcript.append(contentsOf: TranscriptClassifier.classify(report, fallback: .diagnostic))
                self.transcript.append(TranscriptSegment(kind: .success, text: "[TT] 启动自检完成 · \(lineCount) 行"))
                // 输出落定后再弹键盘，否则键盘会盖住刚出来的末行
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    // 命令基本都是 ASCII，直接给英文键盘，省得用户再切一次
                    self.wantsEnglishKeyboard = true
                    self.commandInputFocused = true
                }
            }
        }
    }

    /// 复制全部：输出纯文本，ANSI 转义符已剥离
    private func copyAll() {
        // 自检报告已经逐行进了 transcript，不需要再额外附加一份
        UIPasteboard.general.string = transcript.map { segment -> String in
            segment.kind == .output ? ANSIParser.parse(segment.text).plain : segment.text
        }.joined(separator: "\n")
    }

    private func clearTranscript() {
        transcript = TranscriptClassifier.classify("TT 终端已清空。\n输入 help 查看内置解释器支持的命令。", fallback: .banner)
    }

    /// 把终端滚到底部。
    ///
    /// 两种模式，因为两者诉求相反：
    /// - **追加输出时不带动画**：瀑布流每 10ms 就来一行，若每行都启一次 0.2s 动画，
    ///   动画会被反复打断重启，实际每次只推进一点点，看起来就是"卡住不滚"。
    ///   关掉动画后每行瞬时到位，才有终端刷屏的干脆感。
    /// - **键盘变化时带动画**：需要跟键盘的升降同步，慢一点才自然。
    ///
    /// 键盘通知到达时布局尚未完成，直接滚动会按旧的可视高度算位置而差一屏，
    /// 所以按通知自带的动画时长延后一点再滚。
    private func scrollTranscript(_ proxy: ScrollViewProxy, animated: Bool = false, afterKeyboard note: Notification? = nil) {
        func scroll(animated: Bool) {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("transcript", anchor: .bottom)
                }
            } else {
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) {
                    proxy.scrollTo("transcript", anchor: .bottom)
                }
            }
        }
        guard let note = note,
              let info = note.userInfo,
              let duration = info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
        else {
            scroll(animated: animated)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration * 0.5) {
            scroll(animated: animated)
        }
    }

    // MARK: - 扩展键盘

    /// `^C`：给正在跑的子进程发 SIGINT；空闲时只提示
    private func interruptRunningCommand() {
        let count = RunningProcesses.interruptAll()
        transcript.append(TranscriptSegment(kind: .banner, text: ""))
        if count > 0 {
            transcript.append(TranscriptSegment(
                kind: .warning,
                text: "[TT] 已向 \(count) 个进程发送中断信号 (SIGINT)"))
        } else {
            transcript.append(TranscriptSegment(
                kind: .engineStatus,
                text: "[TT] 当前没有正在执行的命令"))
        }
    }

    /// `tab`：等同于点第一条补全候选
    private func completeFromKeyBar() {
        guard let first = commandSuggestions.first else { return }
        applySuggestion(first)
    }

    /// `↑` `↓` 翻输入历史。delta -1 是更旧的一条，+1 是更新的一条。
    private func stepHistory(_ delta: Int) {
        guard !history.isEmpty else { return }
        let current = historyCursor ?? history.count
        let next = current + delta
        guard next >= 0 else { return }
        if next >= history.count {
            // 往下越过最新一条，回到"空输入"
            historyCursor = nil
            inputController.clear()
            return
        }
        historyCursor = next
        inputController.clear()
        inputController.insert(history[next])
    }

    /// `A/文`：在已安装的多套键盘之间轮换
    private func cycleInputLanguage() {
        guard let language = inputController.cycleInputLanguage() else {
            transcript.append(TranscriptSegment(kind: .banner, text: ""))
            transcript.append(TranscriptSegment(
                kind: .warning,
                text: "[TT] 系统只装了一套输入法，无法切换"))
            return
        }
        transcript.append(TranscriptSegment(kind: .banner, text: ""))
        transcript.append(TranscriptSegment(kind: .engineStatus, text: "[TT] 输入法已切换为 \(language)"))
    }

    // MARK: - 清单管理

    private func persistChecklist() {
        ChecklistStore.save(checklist)
    }

    private func checklistUpdate(at index: Int, with item: ChecklistItem) {
        guard checklist.indices.contains(index) else { return }
        checklist[index] = item
        persistChecklist()
    }

    private func checklistAdd(_ item: ChecklistItem) {
        checklist.append(item)
        persistChecklist()
    }

    private var commandSuggestions: [CommandDoc] {
        let text = command
        let afterLeading = text.drop(while: { $0 == " " || $0 == "\t" })
        let token = String(afterLeading.prefix(while: { !$0.isWhitespace }))
        // 只在"命令名"这一段给出补全；已经敲到第二个词（管道、参数、路径）就不再打扰
        guard !token.isEmpty, !afterLeading.contains(where: { $0.isWhitespace }) else { return [] }

        let needle = token.lowercased()
        let prefixHits = CommandManual.docs.filter { $0.name.lowercased().hasPrefix(needle) }
        // 前缀不够时补上"包含"匹配——用户常常只记得中间几个字母
        let looseHits = CommandManual.docs.filter {
            !$0.name.lowercased().hasPrefix(needle) && $0.name.lowercased().contains(needle)
        }
        return Array((prefixHits + looseHits).prefix(12))
    }

    /// 当前输入的第一段（命令名位置）是否已经正好等于某个命令
    private func currentTokenMatches(_ doc: CommandDoc) -> Bool {
        let afterLeading = command.drop(while: { $0 == " " || $0 == "\t" })
        let token = String(afterLeading.prefix(while: { !$0.isWhitespace }))
        return !token.isEmpty && token.lowercased() == doc.name.lowercased()
    }

    /// 点补全项：没打全就补成命令名；已经打全了就把完整用法填进去
    private func applySuggestion(_ doc: CommandDoc) {
        let text = command
        let leading = text.prefix(while: { $0 == " " || $0 == "\t" }).count
        let afterLeading = text.dropFirst(leading)
        let token = String(afterLeading.prefix(while: { !$0.isWhitespace }))
        let rest = String(afterLeading.dropFirst(token.count))

        if token.lowercased() == doc.name.lowercased() {
            // 名字已经打全，直接给用法模板，省得去翻手册
            command = String(repeating: " ", count: leading) + doc.syntax
        } else {
            command = String(repeating: " ", count: leading) + doc.name + rest
        }
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

/// 正在运行的子进程登记，供扩展键的 `^C` 发送 SIGINT。
/// 命令被应用层拆成多段逐段执行，所以这里可能同时有多个 pid，一并中断。
private enum RunningProcesses {
    private static let lock = NSLock()
    private static var pids: [pid_t] = []

    static func add(_ pid: pid_t) {
        lock.lock()
        if !pids.contains(pid) { pids.append(pid) }
        lock.unlock()
    }

    static func remove(_ pid: pid_t) {
        lock.lock()
        pids.removeAll { $0 == pid }
        lock.unlock()
    }

    /// 返回被中断的进程数
    @discardableResult
    static func interruptAll() -> Int {
        lock.lock()
        let current = pids
        pids.removeAll()
        lock.unlock()
        for pid in current {
            kill(pid, SIGINT)
        }
        return current.count
    }
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

        // 登记 pid，扩展键的 ^C 要靠它发 SIGINT
        RunningProcesses.add(childPID)
        defer { RunningProcesses.remove(childPID) }

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
