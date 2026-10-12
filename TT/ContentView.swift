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

/// 命令手册的一条条目。
///
/// 原来这里是两套东西：`ChecklistItem`（可编辑、带「期望结果」）和 `CommandDoc`（手册静态数据）。
/// 两者都是「命令 + 说明 + 分组」，却各存一份，改一处另一处就对不上。现在合成一种：
/// 手册本身可编辑，内置命令、自定义命令、脚本一视同仁，都能改能删。
struct ManualEntry: Identifiable, Codable {
    /// 脚本怎么跑。单条命令用不到。
    enum ScriptMode: String, Codable {
        /// 逐行喂给 TT 执行器：cd 跨行保持、内建命令可用、危险命令逐行弹警告。
        /// 不支持 for / if 这类 shell 控制流——TT 不会去解释它们。
        case lineByLine
        /// 整段丢给内置 mksh：有完整 shell 语义，但脚本里的 cd 不会改变 TT 当前目录，
        /// 而且 mksh 跑多条命令必须 fork——这台机器 fork 是 SIGBUS 的，慎用。
        case mksh
    }

    var id = UUID()
    /// 实际执行的内容。单条命令就是命令本身；脚本是多行文本。
    var body: String
    /// 用法说明（可留空）
    var syntax: String
    /// 备注（可留空）。原清单里的「期望结果」并到了这里。
    var note: String
    /// 分区。内置条目沿用手册的五类，自定义条目归到「自定义」。
    var category: String
    var isCustom: Bool = false
    /// 只有脚本才有意义
    var scriptMode: ScriptMode? = nil
    /// 条目来源，只用于打标签：builtin 内置 / test 旧测试清单迁过来的 / custom 自己新增。
    ///
    /// **刻意声明成 Optional**：老版本已经存下的 JSON 里没有这个键，
    /// 而非 Optional 属性在 decode 时遇到缺键会直接抛错，整份手册都读不出来、
    /// 静默退回种子数据，把用户改过的东西全冲掉。Optional 走 decodeIfPresent，缺键就是 nil。
    var originTag: String? = nil

    /// 列表里显示的内容：**单条命令显示完整命令**。
    ///
    /// 之前只取第一个词，于是 `ls` 和 `ls -la` 在列表里显示成同一个名字，
    /// 点下去跑的却完全是两回事——等于把「命令名」和「真实命令」当成了同一件事。
    /// 一行就该是一条完整命令，`ls` 和 `ls -la` 自然就分得开。
    /// 脚本是多行的，只显示第一行。
    var displayName: String {
        let firstLine = body.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? body
        return firstLine.trimmingCharacters(in: .whitespaces)
    }

    /// 列表行右侧的标签。脚本有自己更具体的标签，这里就不重复标了。
    var originLabel: String? {
        if isScript { return nil }
        switch originTag {
        case "test": return "测试"
        case "custom": return "自定义"
        default: return isCustom ? "自定义" : nil
        }
    }

    /// 多行，或者被明确标成脚本
    var isScript: Bool { scriptMode != nil || body.contains("\n") }

    /// 脚本里用到的最高位置参数序号（`$1` → 1，`$2` → 2），没有则 0。
    /// 扫出来就能知道点运行时要问几个参数，不必让用户自己声明个数。
    var highestArgumentIndex: Int {
        guard isScript else { return 0 }
        var highest = 0
        var rest = Substring(body)
        while let dollar = rest.firstIndex(of: "$") {
            rest = rest[rest.index(after: dollar)...]
            guard let first = rest.first, first.isNumber else { continue }
            let digits = rest.prefix { $0.isNumber }
            rest = rest[rest.index(rest.startIndex, offsetBy: digits.count)...]
            highest = max(highest, Int(digits) ?? 0)
        }
        return min(highest, 9)
    }
}

enum ManualStore {
    private static let key = "tt.manual.entries.v2"
    /// 旧清单的键。**只读不删**：迁移万一出错，降级重装还能把老清单捞回来。
    private static let legacyKey = "tt.checklist.items.v1"

    /// 旧版清单条目，字段全可选，只为读得出来而存在
    private struct LegacyItem: Codable {
        var id: UUID?
        var group: String?
        var command: String?
        var expect: String?
        var isCustom: Bool?
    }

    static func load() -> [ManualEntry] {
        if let data = UserDefaults.standard.data(forKey: key),
           var decoded = try? JSONDecoder().decode([ManualEntry].self, from: data),
           !decoded.isEmpty {
            // **内置手册加了新工具，得补进已保存的那一份。**
            // 不补的话，只有全新安装才能看到新命令——用户升级 App 却什么都看不到，
            // 这个问题每次加内置工具都会重现一次。
            //
            // 代价：用户手动删掉的**内置**命令下次启动会回来。
            // 这是有意取舍——ttbin 里确实带着那个二进制，它本来就该在手册里；
            // 想彻底不要只能改 UserDefaults，那属于用户自己的操作。
            let known = Set(decoded.map { $0.body })
            var added = false
            for doc in CommandManual.docs where !known.contains(doc.name) {
                decoded.append(ManualEntry(body: doc.name,
                                           syntax: doc.syntax,
                                           note: doc.summary,
                                           category: doc.category,
                                           isCustom: false,
                                           scriptMode: nil,
                                           originTag: "builtin"))
                added = true
            }
            if added { save(decoded) }
            return decoded
        }
        let seeded = seed()
        save(seeded)
        return seeded
    }
    static func save(_ entries: [ManualEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// 首次运行：手册的 32 条内置命令打底，再把旧清单里用户自己写的条目并进来。
    private static func seed() -> [ManualEntry] {
        var entries = CommandManual.docs.map { doc in
            ManualEntry(body: doc.name,
                        syntax: doc.syntax,
                        note: doc.summary,
                        category: doc.category,
                        isCustom: false,
                        scriptMode: nil,
                        originTag: "builtin")
        }
        // 按**完整命令**去重，不是按命令名：手册的 `ls` 和用户的 `ls /nonexistent`
        // 是两条各有意义的记录，都得留下；只有一模一样的 `ls` 才合并成一条。
        var seen = Set(entries.map { $0.body })
        for legacy in migrateLegacy() where !seen.contains(legacy.body) {
            entries.append(legacy)
            seen.insert(legacy.body)
        }
        return entries
    }

    private static func migrateLegacy() -> [ManualEntry] {
        guard let data = UserDefaults.standard.data(forKey: legacyKey),
              let legacy = try? JSONDecoder().decode([LegacyItem].self, from: data)
        else { return [] }
        var out: [ManualEntry] = []
        var seen = Set<String>()
        for item in legacy {
            let text = (item.command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !seen.contains(text) else { continue }
            seen.insert(text)
            let name = text.split(separator: " ").first.map(String.init) ?? text
            // 命令名在内置手册里就沿用手册的分区和用法，否则算自定义条目
            let doc = CommandManual.docs.first { $0.name == name }
            out.append(ManualEntry(body: text,
                                   syntax: doc?.syntax ?? "",
                                   note: (item.expect ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                   category: doc?.category ?? "自定义",
                                   isCustom: doc == nil,
                                   scriptMode: nil,
                                   // 一律标成「测试」：这些条目全都来自旧的测试清单。
                                   // 不管命令名是否撞上内置条目（`ls`、`df` 都会撞），
                                   // 它们和手册里的用法说明不是一回事，列表里必须能一眼分出来。
                                   originTag: "test"))
        }
        return out
    }

    /// 分区展示顺序：手册五个内置分区在前，自定义和脚本分区按字母跟在后面
    static func categoryOrder(of entries: [ManualEntry]) -> [String] {
        var order = CommandManual.categoryOrder.filter { category in
            entries.contains { $0.category == category }
        }
        var extra: [String] = []
        for entry in entries where !order.contains(entry.category) && !extra.contains(entry.category) {
            extra.append(entry.category)
        }
        return order + extra.sorted()
    }
}

/// 一条命令的说明。手册里的数据写死在这里，方便校对文案。
struct CommandDoc: Identifiable {
    let id = UUID()
    let name: String
    let syntax: String
    let summary: String
    let category: String

    /// 语法里声明的选项（已去方括号），用于补全。
    ///
    /// 只取第一段用法：`rm [-f] 文件... / rm -r [-f] 目录` 只取前半的 `[-f]`。
    ///
    /// **顺序必须是「先剥方括号，再判断是不是选项」。**
    /// 手册里几乎所有选项都写成 `[-l]` 这种带括号的占位形式，
    /// 而 `"[-l]".hasPrefix("-")` 是 **false**（开头是 `[` 不是 `-`）。
    /// 之前写成 `.filter { hasPrefix("-") }.map { 去方括号 }`，
    /// 于是**全部 32 条命令的 `optionList` 都返回空数组**，
    /// 补全条永远不出选项——这个错从 `optionList` 引进那天起就在，
    /// 连挂四版没人发现，因为没有任何测试碰过它。
    /// 由 `scripts/completion_selftest.ps1` 的 `ls ` → `[-l, -a]` 用例抓出来。
    var optionList: [String] {
        let firstClause = syntax.components(separatedBy: " / ").first ?? syntax
        return firstClause
            .split(separator: " ")              // 先按空格切，`[-c 列表]` 会切成 `[-c` 和 `列表]`
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("-") && $0.count > 1 }
    }
}

/// 一条补全候选。命令名、选项、路径共用这一套卡片。
/// 把一行输入切成「已经写完的词」和「正在写的那一段」。
///
/// 提成独立类型是为了让 `ttdebug` 能诊断**任意一行**，而不只是输入框里那一行——
/// 要查「刚打完空格那一刻」的状态，就得能拿着当时的字符串重算一遍。
private enum InputParser {
    static func parse(_ command: String) -> (words: [String], token: String) {
        guard let last = command.last else { return ([], "") }
        // 末尾有没有分隔符，决定最后一段算已完成的词，还是刚开始写的空段
        let endsWithSeparator = (last == " " || last == "\t" || last == "\n")
        let cleaned = endsWithSeparator ? String(command.dropLast()) : command
        // 空段一律滤掉：前导空格不该让命令名对不上手册
        let segments = cleaned.split(separator: " ", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty }
        if endsWithSeparator { return (segments, "") }
        // 末尾没分隔符 → 最后一段就是正在写的那个（命令名没打完时 words 为空）
        guard let token = segments.last, !token.isEmpty else { return ([], cleaned) }
        return (Array(segments.dropLast()), token)
    }
}

private struct Completion: Identifiable {
    enum Kind: String { case command, option, path }
    /// 稳定标识。
    ///
    /// **刻意不能用 `let id = UUID()`**：`completions` 是计算属性，每算一次就重新构造一批，
    /// 而 `visibleCompletions` 在 body 里还被访问了两次（判空一次、ForEach 一次）。
    /// 用 UUID 的话每次重渲染都给同一批卡片换一批全新 id，SwiftUI 会把横向 ScrollView
    /// 里的每一行拆了重建，滚动位置跟着乱跳——候选卡片可能来不及显示就又被换掉了。
    /// 用「类型 + 标题」做 id：同一批候选每次算出来完全一致，行才认得出来。
    var id: String { "\(kind.rawValue):\(title)" }
    let kind: Kind
    let title: String
    /// 副标题：命令显示用法说明；选项与路径没有逐项说明
    let detail: String
    /// 已经输入的内容正好等于它——再点一次表示"就按这个来"
    let isExact: Bool
}

/// 路径补全。
///
/// **必须放在 body 之外算**：列目录是 I/O，而 `body` 每次重渲染都会重算一遍属性——
/// 把扫盘放进那里正是之前把 App 卡死的那类错误。
/// 所以由 `onChange(of: command)` 触发，防抖后在后台队列算完再写回 @State，
/// 同目录的列表结果也缓存起来，避免每按一个键都重新扫盘。
private enum PathCompletion {
    /// 只接受目录作参数
    private static let directoryOnly: Set<String> = ["cd", "mkdir"]
    /// 接受任意条目作参数
    private static let anyEntry: Set<String> = [
        "ls", "cat", "cp", "mv", "rm", "touch", "stat",
        "head", "tail", "wc", "grep", "du"
    ]

    static func acceptsPath(_ commandName: String) -> Bool {
        directoryOnly.contains(commandName) || anyEntry.contains(commandName)
    }

    private static func wantsDirectory(_ commandName: String) -> Bool {
        directoryOnly.contains(commandName)
    }

    private struct Entry {
        let name: String
        let isDirectory: Bool
    }

    private static let cacheLock = NSLock()
    private static var listingCache: [String: [Entry]] = [:]

    /// 执行命令后当前目录可能变了，缓存必须丢掉
    static func invalidateCache() {
        cacheLock.lock()
        listingCache.removeAll()
        cacheLock.unlock()
    }

    private static func listing(of directory: String) -> [Entry] {
        // 空串会让 contentsOfDirectory 直接把进程搞崩（v0.4.13 里 `cd /` 秒退就是这个），
        // 所以在入口就把空路径收敛成根目录，宁可给错结果也绝不能崩。
        let key = directory.isEmpty ? "/" : directory
        cacheLock.lock()
        if let cached = listingCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        var result: [Entry] = []
        if let names = try? FileManager.default.contentsOfDirectory(atPath: key) {
            for name in names {
                var isDir: ObjCBool = false
                let full = (key as NSString).appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: full, isDirectory: &isDir) {
                    result.append(Entry(name: name, isDirectory: isDir.boolValue))
                }
            }
        }
        result.sort { $0.name < $1.name }

        cacheLock.lock()
        listingCache[key] = result
        cacheLock.unlock()
        return result
    }

    /// `token` 是光标所在的路径片段，返回补全候选
    static func candidates(commandName: String, token: String, cwd: String) -> [Completion] {
        // 拆成「需要保留的前缀」和「正在输入的名字」
        let prefix: String
        let namePart: String
        if let slash = token.lastIndex(of: "/") {
            prefix = String(token[token.startIndex...slash])
            namePart = String(token[token.index(after: slash)...])
        } else {
            prefix = ""
            namePart = token
        }

        // 要列哪个目录
        let dirToList: String
        if token.hasPrefix("/") {
            // `prefix` 一定非空（至少是 "/"），所以去掉尾斜杠后可能变成空串——
            // 那表示「列根目录」，不能把空串继续往下传。
            let head = String(prefix.dropLast())
            dirToList = head.isEmpty ? "/" : head
        } else if prefix.isEmpty {
            dirToList = cwd
        } else {
            dirToList = (cwd as NSString).appendingPathComponent(String(prefix.dropLast()))
        }

        let dirOnly = wantsDirectory(commandName)
        var out: [Completion] = []

        // cd 的两个万能候选：上一级、家目录
        // 只在还没打出目录分隔符时才给，否则 `cd /` 会补出 `/..`、`/~` 这种看不懂的东西
        if commandName == "cd" && prefix.isEmpty {
            for special in ["..", "~"] where special.hasPrefix(namePart) {
                out.append(Completion(kind: .path,
                                      title: prefix + special,
                                      detail: special == ".." ? "上一级" : "用户主目录",
                                      isExact: false))
            }
        }

        let needle = namePart.lowercased()
        var added = 0
        for entry in listing(of: dirToList) {
            if added >= 12 { break }
            // 与 shell 习惯一致：没显式打点号时不补隐藏文件
            if entry.name.hasPrefix(".") && !needle.hasPrefix(".") { continue }
            guard entry.name.lowercased().hasPrefix(needle) else { continue }
            if dirOnly && !entry.isDirectory { continue }
            out.append(Completion(kind: .path,
                                  title: prefix + entry.name + (entry.isDirectory ? "/" : ""),
                                  detail: entry.isDirectory ? "目录" : "文件",
                                  isExact: false))
            added += 1
        }
        return out
    }
}

enum CommandManual {
    /// 功能分区的展示顺序
    static let categoryOrder = ["文件与目录", "文本处理", "信息查询", "Shell 内建", "诊断探针", "新增工具"]

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
        CommandDoc(name: "seq", syntax: "seq [首个 [步长]] 末尾", summary: "输出一串数字，for 循环要用它", category: "新增工具"),
        CommandDoc(name: "tee", syntax: "tee [-a] 文件...", summary: "一边写文件一边照常输出，-a 追加", category: "新增工具"),
        CommandDoc(name: "nl", syntax: "nl [-b a|t|n] [-v 起始] [-w 宽] [-s 分隔] [文件]", summary: "带行号输出，-b 决定空行和不空行要不要编号", category: "新增工具"),
        CommandDoc(name: "base64", syntax: "base64 [-d] [文件...]", summary: "Base64 编解码，-d 反向解码；不带文件读标准输入", category: "新增工具"),
        CommandDoc(name: "xxd", syntax: "xxd [-r] [文件]", summary: "十六进制转储，-r 把转储还原成字节", category: "新增工具"),
        CommandDoc(name: "basename", syntax: "basename 路径 [后缀]", summary: "去掉目录部分，可再剥一个后缀", category: "新增工具"),
        CommandDoc(name: "dirname", syntax: "dirname 路径...", summary: "去掉最后一段，只留目录", category: "新增工具"),
        CommandDoc(name: "which", syntax: "which [-a] 命令...", summary: "查命令在哪儿，找不到时退出码为 1", category: "新增工具"),
        CommandDoc(name: "id", syntax: "id [-u|-g|-G|-n]", summary: "看 uid / gid / 组 / 用户名，-u 只给 uid", category: "新增工具"),

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
        CommandDoc(name: "ttprobe", syntax: "ttprobe", summary: "探测容器与沙盒环境，产出启动自检报告", category: "诊断探针"),
        // ttdebug 之前只在代码里、没进手册，所以输入它时候选条一个都不出。
        // 手册必须收录 App 真正支持的所有命令，否则候选就是残缺的。
        CommandDoc(name: "ttdebug", syntax: "ttdebug / <命令> ttdebug", summary: "打印补全链路的每一步中间值，排查候选不出现", category: "诊断探针")
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

/// 高危命令识别。
///
/// **一律硬拦截，不分权限等级、没有放行按钮。**
///
/// 当初的分级理由是下面这段，**它是错的**，留在这里当反面教材：
///
/// > 非 root 只能删掉本 App 权限范围内的数据，碰不到 `/`、`/etc`、块设备，
/// > 所以红色警告 + 一次确认就够了。
///
/// 真机上被一句话证伪：`rm -rf /` 之后设置里大片变英文、桌面布局重置、手表连不上。
/// 这些数据全在 `/var/mobile/Library` 底下，**没 root 也写得动**——App 带着
/// `com.apple.private.persona-mgmt` 之类的特权 entitlement，权限模型并不是
/// 「非 root = 只能碰自己的沙盒」。**权限等级不能用来决定要不要给人放行**：
/// 破坏不可逆，而放行只要点一下。真要跑，自己开终端。
enum DangerGuard {
    /// 当前是否以 root 运行。**只用于「关于」页展示，不参与拦截决策。**
    static var hasRoot: Bool { geteuid() == 0 }

    struct Hit {
        let reason: String
    }

    /// 规则按"是否不可逆 / 是否影响整个系统"来定；刻意不拦 `rm -rf /tmp/ttd`
    /// 这类日常操作，否则每次跑测试清单都要被打断一次。
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
        (test: { c in rmTargets(c).contains("/") || rmTargets(c).contains("/*") || rmTargets(c).contains("~") || homeTargets(c) },
         reason: "删除根目录或整个用户目录，系统将无法启动"),
        (test: { c in rmTargets(c).contains(where: { $0.contains("*") || $0.contains("?") }) },
         reason: "使用通配符递归删除，命中范围不可预估"),
        (test: { c in rmRecursive(c) && rmTargets(c).contains(where: { criticalPath($0) }) },
         reason: "递归强制删除系统关键目录"),
        (test: { c in c.contains("find") && (c.contains("-delete") || (c.contains("-exec") && c.contains("rm"))) },
         reason: "find -delete / -exec rm，删哪些文件由遍历结果决定，范围无法预估"),
        (test: { c in
            // 注意大小写：normalized 已把整条命令转成小写，这里必须用小写比对。
            // 之前写成 "chmod-R777/" / "chown-R"，两条规则永远不成立，等于形同虚设——
            // 由 scripts/danger_guard_selftest.ps1 的 `chmod -R 777 /` 用例抓出来的。
            let compact = c.replacingOccurrences(of: " ", with: "")
            return compact.contains("chmod-r777/") || (compact.contains("chown-r") && compact.hasSuffix("/"))
          },
         reason: "递归修改根目录权限或属主"),
        (test: { c in c.contains("killall") || c.contains("kill -9 -1") },
         reason: "批量结束系统进程，可能导致系统不稳定"),
        (test: { c in
            let compact = c.replacingOccurrences(of: " ", with: "")
            return compact.contains(":(){") && compact.contains("};")
          },
         reason: "fork 炸弹，会瞬间耗尽进程与 CPU")
    ]

    static func evaluate(_ command: String) -> Hit? {
        // 先归一化再匹配：多行脚本正文、`sh -c "rm -rf /"`、被引号包住的路径、
        // `rm  -rf  /` 里的多余空白，都必须落到同一条规则上，绕个弯就等于没拦。
        let lowered = normalized(command)
        for rule in rules where rule.test(lowered) {
            return Hit(reason: rule.reason)
        }
        return nil
    }

    /// 匹配前统一小写、去掉引号和续行符、把所有空白压成单个空格。
    /// 只做规范化，不做语义展开——`$HOME` 这类变量由 `homeTargets` 单独识别。
    private static func normalized(_ command: String) -> String {
        command.lowercased()
            .replacingOccurrences(of: "\\", with: " ")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
            .joined(separator: " ")
    }

    // —— 下面几个小工具只服务于上面的规则，让规则本身读起来像一句话 ——
    private static func contains(_ command: String, _ token: String) -> Bool {
        command.contains(token)
    }

    /// 取 rm 后面的操作对象（已小写）
    private static func rmTargets(_ command: String) -> [String] {
        let tokens = command.split(separator: " ").map(String.init)
        guard let head = tokens.firstIndex(where: { $0 == "rm" || $0.hasSuffix("/rm") }) else { return [] }
        return tokens[(head + 1)...].filter { !isRmOption($0) }
    }

    /// 跳过选项，剩下的才是操作对象。
    /// 长选项一并识别，否则 `rm --recursive --force /` 能绕过整张表。
    private static func isRmOption(_ token: String) -> Bool {
        token.hasPrefix("-")
    }

    /// `$HOME`、`${HOME}`、`$home` 以及 `~/` 形式。
    /// 单独拎出来有两个原因：一是规则匹配的是**已经小写**的字符串，
    /// 直接 `contains("$HOME")` 永远不成立；二是 `${HOME}` 里 `$` 和 `home` 并不相邻。
    private static func homeTargets(_ command: String) -> Bool {
        command.contains("$home") || command.contains("{home") || command.contains("~/")
    }

    private static func rmRecursive(_ command: String) -> Bool {
        command.contains("rm -r") || command.contains("--recursive")
    }

    private static func criticalPath(_ path: String) -> Bool {
        let critical = ["/etc", "/var", "/usr", "/bin", "/sbin", "/lib", "/private", "/system", "/applications"]
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return critical.contains { trimmed == $0 || trimmed.hasPrefix($0 + "/") }
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
/// 命令手册。
///
/// 内置命令、自定义命令、脚本都在这一份里，**全部可编辑**——原来的「命令清单」和「命令手册」
/// 是同一件事的两套实现，各自维护一份数据，迟早对不上，这里合成一份。
///
/// 点一条直接跑；左滑编辑或删除；右上角 `+` 新增。左上角原来的 ⋯ 菜单（添加 / 看全部 / 恢复默认）
/// 去掉了：加命令有 `+`，而「查看全部命令」本来就是打开这个面板自己。
struct CommandManualSheet: View {
    @Binding var entries: [ManualEntry]
    /// 点一条就跑。危险命令的拦截由外面负责，手册自己绝不绕过。
    let onRun: (ManualEntry) -> Void
    let onClose: () -> Void

    @State private var byAlphabet = false
    @State private var keyword = ""
    @State private var draft: ManualEntry?
    @State private var draftIsNew = false

    private var filtered: [ManualEntry] {
        let needle = keyword.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return entries }
        return entries.filter {
            $0.body.lowercased().contains(needle)
                || $0.syntax.lowercased().contains(needle)
                || $0.note.lowercased().contains(needle)
                || $0.category.lowercased().contains(needle)
        }
    }

    private var sections: [(key: String, value: [ManualEntry])] {
        var out: [(key: String, value: [ManualEntry])] = []
        if byAlphabet {
            let sorted = filtered.sorted {
                let left = $0.displayName.lowercased()
                let right = $1.displayName.lowercased()
                return left == right ? $0.body < $1.body : left < right
            }
            var order: [String] = []
            var buckets: [String: [ManualEntry]] = [:]
            for entry in sorted {
                let key = String(entry.displayName.prefix(1)).uppercased()
                if buckets[key] == nil { order.append(key) }
                buckets[key, default: []].append(entry)
            }
            for key in order {
                out.append((key: key, value: buckets[key] ?? []))
            }
        } else {
            for category in ManualStore.categoryOrder(of: filtered) {
                let items = filtered.filter { $0.category == category }
                if !items.isEmpty {
                    out.append((key: category, value: items))
                }
            }
        }
        return out
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    Picker("排序方式", selection: $byAlphabet) {
                        Text("按功能分区").tag(false)
                        Text("按字母顺序").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Text("点一条直接执行；左滑可选「编辑」或「删除」。共 \(filtered.count) 条。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                ForEach(sections, id: \.key) { group in
                    Section(group.key) {
                        ForEach(group.value) { entry in
                            row(for: entry)
                        }
                    }
                }
            }
            .navigationTitle("命令手册")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $keyword, prompt: "搜命令、脚本或备注")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭", action: onClose)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        draftIsNew = true
                        draft = ManualEntry(body: "", syntax: "", note: "", category: "自定义",
                                            isCustom: true, scriptMode: nil, originTag: "custom")
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityIdentifier("tt.manual.add")
                }
            }
            .preferredColorScheme(.dark)
            // 编辑弹窗必须挂在这个面板内部：挂在外面的话，本面板还在前台时再 present 会被系统忽略。
            .sheet(item: $draft) { item in
                ManualEntryEditor(entry: item,
                                  isNew: draftIsNew,
                                  knownCategories: ManualStore.categoryOrder(of: entries),
                                  onSave: { updated in
                                      if draftIsNew {
                                          entries.append(updated)
                                      } else if let at = entries.firstIndex(where: { $0.id == updated.id }) {
                                          entries[at] = updated
                                      }
                                      draft = nil
                                  },
                                  onDelete: draftIsNew ? nil : {
                                      entries.removeAll { $0.id == item.id }
                                      draft = nil
                                  },
                                  onCancel: { draft = nil })
            }
        }
        .preferredColorScheme(.dark)
    }

    private func row(for entry: ManualEntry) -> some View {
        Button {
            onRun(entry)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    // 整条命令原样显示：`ls` 和 `ls -la` 必须一眼看得出是两个东西
                    Text(entry.displayName)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.green)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if entry.isScript {
                        tag(entry.scriptMode == .mksh ? "脚本·整段" : "脚本·逐行", Color.purple.opacity(0.4))
                    } else if let label = entry.originLabel {
                        tag(label, Color.blue.opacity(0.35))
                    }
                    Spacer()
                }
                if entry.isScript {
                    let lineCount = entry.body.split(separator: "\n", omittingEmptySubsequences: false).count
                    Text("共 \(lineCount) 行")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                // 旧测试条目沿用了手册的 usage，和它下面那行「备注」重复，藏起来省事
                if !entry.syntax.isEmpty, entry.originTag != "test" {
                    Text(entry.syntax)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                if !entry.note.isEmpty {
                    Text(entry.note)
                        .font(.caption)
                        .foregroundColor(.primary.opacity(0.8))
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 2)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                entries.removeAll { $0.id == entry.id }
            } label: {
                Label("删除", systemImage: "trash")
            }
            Button {
                draftIsNew = false
                draft = entry
            } label: {
                Label("编辑", systemImage: "pencil")
            }
            .tint(Color(red: 0.30, green: 0.52, blue: 0.86))
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color, in: Capsule())
            .foregroundColor(.white)
    }
}

/// 新增 / 编辑一条手册条目。单条命令和脚本共用这一个编辑器，脚本多一块「执行方式」。
struct ManualEntryEditor: View {
    /// 必须原样带回：保存时按 id 匹配。
    /// 漏掉它会把「编辑」变成「追加一条新的」，原条目纹丝不动。
    let entry: ManualEntry
    let isNew: Bool
    let knownCategories: [String]
    let onSave: (ManualEntry) -> Void
    let onDelete: (() -> Void)?
    let onCancel: () -> Void

    @State private var bodyText: String
    @State private var syntax: String
    @State private var note: String
    @State private var category: String
    @State private var isScript: Bool
    @State private var scriptMode: ManualEntry.ScriptMode

    init(entry: ManualEntry,
         isNew: Bool,
         knownCategories: [String],
         onSave: @escaping (ManualEntry) -> Void,
         onDelete: (() -> Void)? = nil,
         onCancel: @escaping () -> Void) {
        self.entry = entry
        self.isNew = isNew
        self.knownCategories = knownCategories
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        _bodyText = State(initialValue: entry.body)
        _syntax = State(initialValue: entry.syntax)
        _note = State(initialValue: entry.note)
        _category = State(initialValue: entry.category)
        _isScript = State(initialValue: entry.scriptMode != nil || entry.body.contains("\n"))
        _scriptMode = State(initialValue: entry.scriptMode ?? .lineByLine)
    }

    /// 不是脚本时把换行压成空格，免得一条"命令"里其实藏着好几条
    private var normalizedBody: String {
        let trimmed = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        return isScript ? trimmed : trimmed.replacingOccurrences(of: "\n", with: " ")
    }

    private var trimmedCategory: String {
        let trimmed = category.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "自定义" : trimmed
    }

    /// 扫出来的参数个数：脚本里写了 $2 就有两个，运行时弹两个输入框
    private var argumentCount: Int {
        ManualEntry(body: normalizedBody,
                    syntax: "",
                    note: "",
                    category: "",
                    isCustom: true,
                    scriptMode: isScript ? scriptMode : nil).highestArgumentIndex
    }

    private var canSave: Bool { !normalizedBody.isEmpty }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("命令")) {
                    Toggle("这是脚本（多行）", isOn: $isScript)
                        .font(.subheadline)
                }
                Section(header: Text(isScript ? "脚本内容" : "命令")) {
                    if isScript {
                        TextEditor(text: $bodyText)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(minHeight: 150)
                            .autocorrectionDisabled(true)
                            .textInputAutocapitalization(.never)
                    } else {
                        TextField("例如 ls -l /etc", text: $bodyText)
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled(true)
                            .textInputAutocapitalization(.never)
                    }
                }
                if isScript {
                    Section(header: Text("执行方式")) {
                        Picker("跑法", selection: $scriptMode) {
                            Text("逐行执行").tag(ManualEntry.ScriptMode.lineByLine)
                            Text("整段 mksh").tag(ManualEntry.ScriptMode.mksh)
                        }
                        .pickerStyle(.segmented)
                        Text(scriptMode == .lineByLine
                             ? "一行一条命令，按顺序跑。cd 跨行保持，echo / pwd 这类内建照常可用；不支持 for、if 这类 shell 控制流。"
                             : "完整 shell 语义，支持循环和条件。代价有两个：脚本里的 cd 不会改变 TT 的当前目录；mksh 跑第二条命令必须 fork，而本机 fork 是坏的，可能直接闪退。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        Text(argumentCount > 0
                             ? "检测到 $1…$\(argumentCount)，点运行时会先问你 \(argumentCount) 个参数。"
                             : "在内容里写 $1 $2 即可使用参数，点运行时会逐个询问。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                Section(header: Text("分区")) {
                    TextField("例如 文件与目录", text: $category)
                    if !knownCategories.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(knownCategories, id: \.self) { name in
                                    Button {
                                        category = name
                                    } label: {
                                        Text(name)
                                            .font(.caption)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(category == name ? Color.green.opacity(0.85) : Color.gray.opacity(0.35),
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
                Section(header: Text("用法说明")) {
                    TextField(isScript ? "可留空" : "例如 ls [-l] [-a] [路径]", text: $syntax)
                        .font(.system(.footnote, design: .monospaced))
                }
                Section(header: Text("备注")) {
                    TextField("可留空", text: $note)
                }
                if let onDelete = onDelete {
                    Section {
                        Button(role: .destructive, action: onDelete) {
                            Label("删除这条", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "新增" : "编辑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(ManualEntry(id: entry.id,
                                           body: normalizedBody,
                                           syntax: syntax.trimmingCharacters(in: .whitespacesAndNewlines),
                                           note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                                           category: trimmedCategory,
                                           isCustom: entry.isCustom || isNew,
                                           scriptMode: isScript ? scriptMode : nil,
                                           // 编辑时保留原来源；新增的一律算「自定义」
                                           originTag: isNew ? "custom" : entry.originTag))
                    }
                    .disabled(!canSave)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// 高危命令拦截。
///
/// **只有一种形态：告诉用户拦住了什么，然后没有然后。**
/// 原来这里还有一个「仍然执行」的确认分支，昨晚的事故就是从那个按钮点进去的：
/// 它当时的前提是"没 root 就只能删 App 自己的数据"，而这个前提是错的。
/// 现在这个分支整个删掉，`hardBlock` 参数也一并去掉——不给放行入口留任何复活的口子。
struct DangerConfirmSheet: View {
    let command: String
    let reason: String
    let onCancel: () -> Void

    var body: some View {
        NavigationView {
            content
                .navigationTitle("高危命令拦截")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("知道了", action: onCancel)
                    }
                }
        }
        .interactiveDismissDisabled()
        .preferredColorScheme(.dark)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .foregroundColor(Color(red: 0.88, green: 0.42, blue: 0.42))
                Text("已拦截，不会执行")
                    .font(.headline)
                    .foregroundColor(Color(red: 0.94, green: 0.45, blue: 0.45))
            }

            Text(reason)
                .font(.callout)
                .foregroundColor(Color(red: 0.94, green: 0.55, blue: 0.55))

            Text(command)
                .font(.system(.footnote, design: .monospaced))
                .foregroundColor(.white)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(red: 0.28, green: 0.10, blue: 0.10), in: RoundedRectangle(cornerRadius: 8))

            Text("TT 一律不执行这类命令，没有放行入口。真要跑，请自己开终端。")
                .font(.footnote)
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding(18)
        .background(Color(red: 0.10, green: 0.06, blue: 0.06))
    }
}

/// 清单条目的编辑/新增弹窗。两条路径共用一套表单。
// 原来的 ChecklistEditorSheet 已并入 ManualEntryEditor：
// 清单和手册合成一份之后，「编辑清单条目」和「编辑手册条目」不再需要两套表单。

/// 运行带参数的脚本时，先把 `$1` `$2` 问清楚。
///
/// 个数是扫脚本内容扫出来的，用户不用自己声明「这条要几个参数」。
struct ScriptArgumentsSheet: View {
    let entry: ManualEntry
    let count: Int
    @Binding var arguments: [String]
    let onRun: () -> Void
    let onCancel: () -> Void

    private var missingCount: Int {
        arguments.filter { $0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("脚本")) {
                    Text(entry.displayName)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.green)
                    Text("脚本里用到 $1…$\(count)，按顺序填。留空视为空字符串。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    if missingCount > 0 {
                        Text("还有 \(missingCount) 个空着，会按空字符串传进去。")
                            .font(.footnote)
                            .foregroundColor(.orange)
                    }
                }
                Section(header: Text("参数")) {
                    ForEach(0..<count, id: \.self) { index in
                        HStack {
                            Text("$\(index + 1)")
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.green)
                                .frame(width: 34, alignment: .leading)
                            TextField("参数 \(index + 1)", text: binding(at: index))
                                .font(.system(.body, design: .monospaced))
                                .autocorrectionDisabled(true)
                                .textInputAutocapitalization(.never)
                        }
                    }
                }
            }
            .navigationTitle("运行脚本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("运行", action: onRun)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func binding(at index: Int) -> Binding<String> {
        Binding(
            get: { index < arguments.count ? arguments[index] : "" },
            set: { newValue in
                while arguments.count <= index { arguments.append("") }
                arguments[index] = newValue
            })
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


// MARK: - 扩展键盘（v0.5）

/// 扩展键盘上的一个键。
///
/// **只留真正补不上缺的，而且全都在附件栏那一行里。**
/// `^C` 曾经也是附件栏的键，现在挪到输入框最右边常驻——
/// 命令跑着的时候一眼就看得见，比藏在要展开的那一行里有用得多。
///
/// 删过四批（真机反馈，全都是「系统里已经有更快的」）：
/// `⌫` 退格、`←` `→` 光标、`esc` 清行、`^C`。
enum ExtKey: Hashable {
    /// 普通字符：在光标处插入
    case text(String)
    /// ↑↓：翻输入历史
    case historyUp
    case historyDown
}

/// 操作输入框的通道。
///
/// `UIViewRepresentable` 的 SwiftUI 侧拿不到内部的 `UITextField`，靠一个持有弱引用的对象
/// 把方法递出去。**必须用弱引用**：SwiftUI 重建视图时旧控件会被释放，强引用会把它拖住不释放。
final class InputFieldBridge: ObservableObject {
    /// 变化时刷新对 UIKit 侧的订阅（比如附件栏重建）
    @Published private(set) var revision = 0

    private weak var field: UITextField?
    /// 外部文本变化时回调，把程序化写入同步回 SwiftUI 的绑定
    var onTextChange: ((String) -> Void)?

    func attach(_ field: UITextField) {
        self.field = field
        revision &+= 1
    }

    func focus() {
        field?.becomeFirstResponder()
    }

    var text: String {
        get { field?.text ?? "" }
        set { setText(newValue) }
    }

    /// 整行替换，**光标落到末尾**（↑↓ 翻历史用）
    func replaceWholeLine(_ value: String) {
        guard let field = field else { return }
        field.text = value
        moveCaretToEnd()
        notify()
    }

    // MARK: 光标与编辑
    //
    // 全部走 `offset(from:to:)` + `position(from:offset:)`，
    // 不碰 `compare(_:to:options:)`（UITextField 上没有这个方法）
    // 也不碰 `UITextRange.length`（UITextRange 只有 start/end，没有长度）。
    // 这两个坑上一版都踩了，编译直接报出来。
    private func moveCaretToEnd() {
        guard let field = field,
              let collapsed = field.textRange(from: field.endOfDocument, to: field.endOfDocument)
        else { return }
        field.selectedTextRange = collapsed
    }
    /// 光标位置，UTF-16 偏移，和 UITextInput 一致
    private func caretOffset() -> Int {
        guard let field = field, let range = field.selectedTextRange else { return 0 }
        // UITextRange 的 start/end 是**非 Optional**，不用解包
        return field.offset(from: field.beginningOfDocument, to: range.start)
    }
    private func setCaret(_ offset: Int) {
        guard let field = field else { return }
        let length = (field.text ?? "").utf16.count
        let clamped = max(0, min(offset, length))
        // UITextInput 的 Optional 规律（三轮编译才摸清，记在这里免得再踩）：
        //   UITextRange.start / .end            非 Optional
        //   position(from:offset:)              Optional
        //   textRange(from:to:)                 Optional
        //   UITextRange                         没有 length 属性，只有 start/end
        guard let position = field.position(from: field.beginningOfDocument, offset: clamped),
              let collapsed = field.textRange(from: position, to: position)
        else { return }
        field.selectedTextRange = collapsed
    }
    /// 自动配对的括号与引号。**常开，没有开关**——
    /// 打字时自动补齐本来就不该要用户记着开或关。
    static let pairOpeners: [Character: Character] = [
        "(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'"
    ]
    /// 在光标处插入。开了配对的话，括号引号会自动补齐闭合、光标停在中间；
    /// 已经选中一段内容时会被这对符号包起来；右边本来就是闭合符号就跳过去，不重复插。
    func insert(_ value: String) {
        guard let field = field else { return }
        if value.count == 1, let ch = value.first, let closer = Self.pairOpeners[ch] {
            let offset = caretOffset()
            let text = field.text ?? ""
            let ns = text as NSString
            let after = offset < ns.length ? ns.substring(with: NSRange(location: offset, length: 1)) : ""
            // 右边已经是闭合符号（正在 `"…"` 中间打 `"`）→ 直接跳过去
            if after == String(closer) {
                setCaret(offset + 1)
                notify()
                return
            }
            // 选中了内容 → 包起来
            if let range = field.selectedTextRange,
               field.offset(from: range.start, to: range.end) > 0,
               let selected = field.text(in: range), !selected.isEmpty {
                field.replace(range, withText: "\(ch)\(selected)\(closer)")
                notify()
                return
            }
            // 普通配对：补出闭合，光标退回一格停在中间
            field.insertText("\(ch)\(closer)")
            setCaret(offset + 1)
            notify()
            return
        }
        if let range = field.selectedTextRange {
            field.replace(range, withText: value)
        } else {
            field.text = (field.text ?? "") + value
            moveCaretToEnd()
        }
        notify()
    }
    private func setText(_ value: String) {
        guard let field = field else { return }
        field.text = value
        moveCaretToEnd()
        notify()
    }
    private func notify() {
        onTextChange?(field?.text ?? "")
        revision &+= 1
    }
}
/// 输入框。
///
/// **必须换成 UIKit 的 `UITextField`**：要挂 `inputAccessoryView`（扩展键盘），
/// 还要读 `selectedTextRange`（括号引号配对时光标要停在中间）——
/// SwiftUI 的 `TextField` 这两样都不给。
/// 换成 UIKit 之后 `inputAccessoryView` 也变成原生能力，扩展键盘不用在 App 里挤空间。
///
/// 代价：输入框是所有功能的地基，换掉之后中文界面、长按选择、复制、输入历史、
/// 补全、危险命令拦截**全部要重新验一遍**。
struct TerminalTextField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let bridge: InputFieldBridge
    let onSubmit: () -> Void
    /// 符号键那一行是否展开。
    /// 变了要重建附件栏——收起时是 `nil`（压根不挂），展开时是一个定高的视图。
    let showSymbols: Bool

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.text = text
        field.placeholder = placeholder
        field.font = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        field.textColor = .white
        field.tintColor = UIColor(red: 0.36, green: 0.84, blue: 0.47, alpha: 1)
        field.keyboardType = .asciiCapable
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        field.returnKeyType = .send
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        field.accessibilityIdentifier = "tt.command.input"
        // 收起时**完全不挂**附件栏，键盘直接贴着输入框（真机反馈：默认就该干净）。
        // 挂一个高度 0 的空视图不算「没挂」，UIKit 照样给它留位置。
        if showSymbols {
            field.inputAccessoryView = KeyboardAccessory.makeView(showSymbols: true,
                                                                  bridge: bridge,
                                                                  onKey: context.coordinator.handle)
        }
        bridge.attach(field)
        context.coordinator.parent = self
        return field
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        context.coordinator.parent = self
        // 只有外部真的改了内容才写回，否则光标会被弹回末尾。
        if uiView.text != text {
            uiView.text = text
        }
        // 有没有挂着附件栏 + 高度对不对，两个都要看。
        let expected = KeyboardAccessory.height(showSymbols: showSymbols)
        let installedHeight = uiView.inputAccessoryView?.frame.height ?? 0
        if showSymbols {
            if installedHeight != expected {
                uiView.inputAccessoryView = KeyboardAccessory.makeView(showSymbols: true,
                                                                         bridge: bridge,
                                                                         onKey: context.coordinator.handle)
                uiView.reloadInputViews()
            }
        } else if uiView.inputAccessoryView != nil {
            uiView.inputAccessoryView = nil
            uiView.reloadInputViews()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: TerminalTextField?

        @objc func editingChanged(_ field: UITextField) {
            // 附件栏上的括号走 bridge.insert（有配对）；
            // 系统键盘的括号走这里，得自己认出来，不然两条路径行为不一致。
            let newText = field.text ?? ""
            let oldText = parent?.text ?? ""
            var result = newText
            if newText.count == oldText.count + 1,
               newText.hasPrefix(oldText),
               let last = newText.last,
               let closer = InputFieldBridge.pairOpeners[last] {
                result = newText + String(closer)
                // 光标停在中间：位置取 newText 的末尾，这在 result 里正好是两者之间
                if let position = field.position(from: field.beginningOfDocument,
                                                offset: newText.utf16.count),
                   let collapsed = field.textRange(from: position, to: position) {
                    field.text = result
                    field.selectedTextRange = collapsed
                }
            }
            parent?.text = result
        }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent?.onSubmit()
            return false
        }

        /// 附件栏的按键回调直接交给 bridge 执行
        func handle(_ key: ExtKey) {
            guard let bridge = parent?.bridge else { return }
            TerminalTextField.perform(key, bridge: bridge)
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            // 键盘弹完之后**验收一次**：现在挂着的附件栏，是不是当前该有的那一个。
            verifyAccessoryBar(afterKeyboardSettles: textField)
        }

        /// **这是兜底。**
        ///
        /// 附件栏本体是 v0.5.2 那套已验证能启动的写法，只改了「默认不挂」和「单行」。
        /// 这里留着是因为「键盘进场动画中途不要动输入视图」这条规矩总得有个执行点：
        /// 真出问题时它能自愈一次，代价只是一次 `reloadInputViews()`。
        ///
        /// 时机很要紧：
        /// - 同步调 → 正在动画中途，UIKit 把改动排到动画之后，safe area 错位；
        /// - 下一轮主循环调 → 动画还没完，同上（v0.5.2 踩的就是这个，没修好）；
        /// - 动画走完再调 → 键盘已稳住，这时重建立刻生效，也不至于反过来搅动画。
        private func verifyAccessoryBar(afterKeyboardSettles textField: UITextField) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                guard let parent = self.parent else { return }
                let symbols = parent.showSymbols
                // 比实际挂着的附件栏高度。
                let installed = textField.inputAccessoryView?.frame.height ?? 0
                if symbols {
                    let expected = KeyboardAccessory.height(showSymbols: true)
                    guard installed != expected else { return }
                    textField.inputAccessoryView = KeyboardAccessory.makeView(showSymbols: true,
                                                                              bridge: parent.bridge,
                                                                              onKey: self.handle)
                } else {
                    // 收起态要的是 nil。挂一个高度 0 的空视图不算数——
                    // UIKit 照样会给它留位置，键盘就还是被顶开一条缝。
                    guard textField.inputAccessoryView != nil else { return }
                    textField.inputAccessoryView = nil
                }
                textField.reloadInputViews()
            }
        }
    }

    /// 把 ExtKey 翻译成对输入框的操作。
    /// 除了 tab / ^C，其余都在这里就地完成；tab 和 ^C 需要 App 层的数据，走通知。
    static func perform(_ key: ExtKey, bridge: InputFieldBridge) {
        switch key {
        case .text(let value): bridge.insert(value)
        case .historyUp: NotificationCenter.default.post(name: .ttExtHistory, object: -1)
        case .historyDown: NotificationCenter.default.post(name: .ttExtHistory, object: 1)
        }
    }
}

extension Notification.Name {
    static let ttExtHistory = Notification.Name("tt.ext.history")
}

/// 附件栏上的一个键。
///
/// **做成 struct，不做成元组。**
///
/// 原来是 `[(String, ExtKey, Bool)]`，结果 `ForEach` 的 `id:` 写 `\.\.1` 没问题、
/// 写 `\.label` 就直接编译报错：
/// ```
/// error: value of tuple type '(String, ExtKey)' has no member 'label'
/// ```
/// 因为 Swift **不支持指向元组成员的 key path**。
/// `\.0` / `\.1` 之所以能用，那是**数组下标**的 key path，不是元组成员——
/// 一个纯属巧合能过的写法，换成具名字段就直接挂。
///
/// v0.5.4 记一笔：这个坑靠 CI 才暴露出来，本机没编译器看不出来。
struct ExtKeySpec: Identifiable {
    let label: String
    let key: ExtKey
    let danger: Bool
    /// 用 label 当唯一标识：同一行里标签本来就不重复。
    var id: String { label }
}

/// 附件栏的构造与尺寸。
///
/// **默认不挂。** 收起时 `inputAccessoryView` 就是 `nil`，
/// 键盘直接贴着输入框——真机反馈「刚打开就该干净」。
/// 挂一个高度 0 的空视图**不算没挂**，UIKit 照样给它留位置，键盘还是会被顶开一条缝。
enum KeyboardAccessory {
    /// 展开时那一行的高度。收起时根本没有附件栏，所以没有「收起态的高度」。
    static let barRowHeight: CGFloat = 38

    /// 那一行里排在符号前面的键。
    ///
    /// **每一个都是 iOS 键盘给不了的**：↑↓ 管输入历史。
    ///
    /// 删掉过的（真机反馈，全都是「系统里已经有更快的」）：
    /// `⌫` 退格——系统键盘本来就有；`←` `→`——直接拖光标更快；
    /// `esc`——三击全选再删；`⇥`——路径候选本来就摆在下面，划一下就能点；
    /// `^C`——挪到输入框最右边常驻，命令跑着的时候一眼就看得见，
    /// 比藏在要展开的那一行里有用得多。
    static let controlKeys: [ExtKeySpec] = [
        ExtKeySpec(label: "↑", key: .historyUp, danger: false),
        ExtKeySpec(label: "↓", key: .historyDown, danger: false)
    ]

    /// 全部是单个字符。`||` `&&` `>>` `~/` 这类组合不做——
    /// 组合符号按两下就能打出来，专门给它一个键不值当，附件栏的位置比符号数量值钱。
    static let symbolKeys: [ExtKeySpec] = [
        "|", "&", "/", ">", "<", ";", "~", "-", "_", ".", "=", "*",
        "?", "'", "\"", "$", "#", "%", "!", "@", "[", "]", "(", ")"
    ].map { ExtKeySpec(label: $0, key: .text($0), danger: false) }

    /// 那一行的全部按键：控制键在前，符号在后。
    static var barKeys: [ExtKeySpec] {
        controlKeys + symbolKeys
    }

    /// **这个数必须等于 ExtendedKeyboardBar 实际渲染出来的高度。**
    static func height(showSymbols: Bool) -> CGFloat {
        showSymbols ? barRowHeight : 0
    }

    static func makeView(showSymbols: Bool,
                         bridge: InputFieldBridge,
                         onKey: @escaping (ExtKey) -> Void) -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width,
                                             height: height(showSymbols: showSymbols)))
        container.backgroundColor = UIColor(red: 0.13, green: 0.14, blue: 0.16, alpha: 1)
        // 顶部一条细线，和终端区分开
        let line = UIView(frame: CGRect(x: 0, y: 0, width: container.bounds.width, height: 1))
        line.backgroundColor = UIColor(white: 1, alpha: 0.12)
        container.addSubview(line)

        let host = UIHostingController(rootView: ExtendedKeyboardBar(bridge: bridge, onKey: onKey))
        host.view.backgroundColor = .clear
        let child = host.view!
        child.frame = container.bounds
        // **只跟着宽度变，高度锁死**：内容高度一旦能撑开容器，
        // UIKit 排键盘时就会拿到一个不断变化的高度，输入行和键盘互相顶、越顶越歪。
        child.autoresizingMask = [.flexibleWidth]
        container.addSubview(child)
        // hosting controller 必须跟着 container 一起活：它持有 view，
        // 控制器一旦释放，view 也会被拆掉。用关联对象保活是最省事的做法。
        objc_setAssociatedObject(container, "tt.ext.host", host, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return container
    }
}

/// 附件栏界面。贴在系统键盘正上方，不占 App 的终端显示区。
/// **只有一行**：`›` 拉出来，再点 `›` 收起。
struct ExtendedKeyboardBar: View {
    let bridge: InputFieldBridge
    let onKey: (ExtKey) -> Void
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(KeyboardAccessory.barKeys) { spec in
                    keyButton(spec.label, key: spec.key, danger: spec.danger)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
        }
        .frame(height: KeyboardAccessory.barRowHeight)
        // **`.ignoresSafeArea()` 必须排在 `.frame(height:)` 前面。**
        // 这个 UIHostingController 并不在窗口里，它拿到的安全区内边距是来路不明的假值；
        // 但反过来写就等于让它去扩张一个已经定死高度的容器——
        // 容器被顶高 → UIKit 按新高度排键盘 → 内容再被顶高，如此循环。
        //
        // 顺序写错的后果不只是「显得高」，而是布局越算越离谱直到被杀进程。
        .ignoresSafeArea()
        .background(Color(red: 0.13, green: 0.14, blue: 0.16))
    }
    private func keyButton(_ label: String, key: ExtKey, danger: Bool) -> some View {
        Button {
            onKey(key)
        } label: {
            Text(label)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(danger ? Color.white : Color.white.opacity(0.92))
                .frame(minWidth: 36, minHeight: 26)
                .padding(.horizontal, 5)
                .background(danger ? Color(red: 0.76, green: 0.24, blue: 0.24)
                                   : Color(white: 1, opacity: 0.13),
                            in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tt.ext.\(label)")
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
    /// ↑↓ 翻历史时的位置。nil = 没在翻历史中。
    @State private var historyCursor: Int?
    /// 路径补全结果。由 onChange 触发、后台算好后写回；body 只渲染，不做 I/O
    @State private var pathCompletions: [Completion] = []
    /// 命令名/选项候选。**由 onChange 算好写进来，不在 body 里现算。**
    ///
    /// 之前它是 body 里的计算属性：出了问题只能读代码猜，而这一条已经连猜四版全错。
    /// 改成显式状态有两个好处——算的时候顺手打一行日志（见 `computeOptionCompletions`），
    /// 渲染时拿的是一份确定快照，于是「**算出来了但没显示**」和「**压根没算出来**」
    /// 这两件事能立刻分开，不用再靠推理。
    @State private var optionCompletions: [Completion] = []
    /// 最近一次自动打出来的候选自检行，供 ttdebug 一并回显
    @State private var optionSnapshot = ""
    /// 最近一次「有内容的输入」快照。用户直接发 `ttdebug` 时诊断它——
    /// 否则得先把输入框改成 `ttdebug`，那一刻的状态早没了。
    @State private var lastProbe = ""
    @State private var showHistory = false
    /// 命令手册。原来的「命令清单」和「命令手册」合并成这一份，全部可编辑。
    @State private var showManual = false
    @State private var manualEntries: [ManualEntry] = ManualStore.load()
    /// 待填参数的脚本：内容里有 $1 $2 时，点运行会先弹这个
    @State private var scriptAwaitingArguments: ManualEntry?
    @State private var scriptArguments: [String] = []
    @State private var diagnosticReport = ""
    /// 权限检测报告。按需生成——它要真的建测试文件，不能塞进启动自检。
    @State private var rootReport = ""
    @State private var rootReportRunning = false
    @State private var showCopiedTip = false
    @State private var showDiagnostics = false
    @State private var pendingDanger: DangerGuard.Hit?
    @State private var pendingDangerCommand = ""
    /// 危险确认要放行的是一条脚本时，把脚本和已填好的参数挂在这儿
    @State private var pendingDangerScript: ManualEntry?
    @State private var pendingScriptArguments: [String] = []
    @State private var isExecuting = false
    /// 输入框焦点。自检跑完后要自动弹键盘，靠它把输入框提到响应者首位。
    /// 符号页是否展开。由输入框左侧的 `›` 切换。
    @State private var showSymbolKeys = false
    /// 操作输入框的通道。扩展键盘的按键、↑↓ 翻历史都要靠它。
    @StateObject private var inputBridge = InputFieldBridge()
    /// 扩展键盘的三个通知观察者（历史 / tab 补全 / ^C）。视图消失时必须注销。
    @State private var extKeyObservers: [NSObjectProtocol]?
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

            // 补全条：补命令名 / 补选项 / 补路径三种形态共用这张卡。
            //
            // **先算一次存进 items**：直接写 `if !visibleCompletions.isEmpty` + `ForEach(visibleCompletions)`
            // 会把整个候选列表算两遍，两遍结果还是两份不同的对象，白白多一倍开销。
            let items = visibleCompletions
            if !items.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(items) { candidate in
                            Button {
                                applyCompletion(candidate)
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(candidate.title)
                                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                    if !candidate.detail.isEmpty {
                                        Text(candidate.detail)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(candidate.isExact ? Color.green.opacity(0.28)
                                                               : Color(red: 0.16, green: 0.17, blue: 0.20),
                                            in: RoundedRectangle(cornerRadius: 7))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7)
                                        .stroke(candidate.isExact ? Color.green.opacity(0.65) : Color.clear,
                                                lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("tt.suggestion.\(candidate.title)")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                }
                .background(Color(red: 0.10, green: 0.11, blue: 0.13))
                .accessibilityIdentifier("tt.suggestions")
            }

            HStack(spacing: 8) {
                // `›` 是那一行符号键的开关：点一下在键盘上方拉出来，再点收起。
                // **默认是收起的**——刚打开 App 只有输入框和键盘，干干净净（真机反馈）。
                // 它挂在 inputAccessoryView 上，不占终端显示区：
                // 系统键盘本来就吃掉一半屏幕，再在 App 里加一块面板就只剩几行输出了。
                Button {
                    showSymbolKeys.toggle()
                } label: {
                    Text("›")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(showSymbolKeys ? Color.yellow : Color.green)
                        .frame(width: 24, height: 26)
                        .background(Color.white.opacity(showSymbolKeys ? 0.18 : 0),
                                    in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("扩展键盘符号页")
                .accessibilityIdentifier("tt.ext.toggle")
                TerminalTextField(text: $command,
                                  placeholder: "输入命令，例如 pwd、ls、date",
                                  bridge: inputBridge,
                                  onSubmit: submitCommand,
                                  showSymbols: showSymbolKeys)
                // **必须有高度约束**：UITextField 报给 SwiftUI 的固有高度不合适，
                // 放进 HStack 会纵向撑开，输入行那整条 HStack 变成一大块空白，
                // › 和发送箭头被顶到中间（v0.5.0 真机反馈的问题）。
                .frame(height: 34)
                Button {
                    showManual = true
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 17, weight: .medium))
                }
                .accessibilityLabel("命令手册")
                .accessibilityIdentifier("tt.manual")

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

                // ^C 常驻在输入行最右边，红色。
                //
                // 以前它藏在附件栏里，要先展开才看得见；可它的使用时机恰恰是
                // 「命令正在跑」——那会儿人正盯着终端输出，不会想到去展开一行按键。
                // 放这儿常驻，跑到一半扫一眼就按得到。
                // 空闲时置灰（disabled），免得看着像随时能按。
                Button(action: cancelRunningCommand) {
                    Text("^C")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(width: 34, height: 26)
                        .background(Color(red: 0.76, green: 0.24, blue: 0.24),
                                    in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .disabled(!isExecuting)
                .accessibilityLabel("取消正在执行的命令")
                .accessibilityIdentifier("tt.cancel")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(red: 0.12, green: 0.13, blue: 0.15))
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            // 扩展键盘改的是 UIKit 里的 UITextField，SwiftUI 不知道内容变了，
            // 这里把程序化写入（符号键、光标移动、翻历史）同步回 @State。
            inputBridge.onTextChange = { newText in
                command = newText
            }
            extKeyObservers = [
                NotificationCenter.default.addObserver(forName: .ttExtHistory, object: nil, queue: .main) { note in
                    let step = (note.object as? Int) ?? 0
                    if step < 0 {
                        self.recallHistory(direction: -1)
                    } else {
                        self.recallHistory(direction: 1)
                    }
                }
            ]
            runStartupDiagnostics()
        }
        .onDisappear {
            extKeyObservers?.forEach { NotificationCenter.default.removeObserver($0) }
            extKeyObservers = nil
        }
        .onChange(of: command) { newValue in
            // 快照只记「非空、且不是在敲 ttdebug 本身」，否则诊断到的就是 ttdebug 自己
            if !newValue.isEmpty, !newValue.hasSuffix("ttdebug") {
                lastProbe = newValue
            }
            optionCompletions = computeOptionCompletions(for: newValue)
            refreshPathCompletions()
        }
        .sheet(isPresented: $showManual) {
            CommandManualSheet(entries: $manualEntries,
                               onRun: runManualEntry,
                               onClose: { showManual = false })
                .onDisappear { persistManual() }
        }
        .sheet(isPresented: Binding(
            get: { scriptAwaitingArguments != nil },
            set: { if !$0 { scriptAwaitingArguments = nil } }
        )) {
            if let entry = scriptAwaitingArguments {
                ScriptArgumentsSheet(entry: entry,
                                     count: entry.highestArgumentIndex,
                                     arguments: $scriptArguments,
                                     onRun: {
                                         scriptAwaitingArguments = nil
                                         showManual = false
                                         DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                             launchScript(entry, arguments: scriptArguments)
                                         }
                                     },
                                     onCancel: { scriptAwaitingArguments = nil })
            }
        }
        .sheet(isPresented: Binding(
            get: { pendingDanger != nil },
            set: { if !$0 { pendingDanger = nil; pendingDangerCommand = "" } }
        )) {
            if let hit = pendingDanger {
                DangerConfirmSheet(command: pendingDangerCommand,
                                   reason: hit.reason,
                                                                      onCancel: {
                                       pendingDanger = nil
                                       pendingDangerCommand = ""
                                       pendingDangerScript = nil
                                       pendingScriptArguments = []
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
                        InfoRow(label: "手册条目", value: "\(manualEntries.count) 条")
                        InfoRow(label: "其中脚本", value: "\(manualEntries.filter { $0.isScript }.count) 条")
                        InfoRow(label: "Shell", value: "内置 mksh")
                        InfoRow(label: "高危命令拦截", value: "硬拦截 · 无放行入口")
                        InfoRow(label: "单条命令超时", value: "\(ProcessLauncher.defaultTimeoutSeconds) 秒")
                    }
                    Section("运行环境") {
                        InfoRow(label: "系统", value: UIDevice.current.systemName + " " + UIDevice.current.systemVersion)
                        InfoRow(label: "设备", value: UIDevice.current.model)
                        InfoRow(label: "当前目录", value: FileManager.default.currentDirectoryPath)
                        InfoRow(label: "运行身份", value: DangerGuard.hasRoot ? "root (uid 0)" : "uid \(geteuid())")
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
                    Section {
                        NavigationLink {
                            ScrollView {
                                if rootReport.isEmpty {
                                    Text(rootReportRunning
                                         ? "正在检测……检测会真的建临时文件再删掉，需要几秒。"
                                         : "还没有检测。点右上角的「开始检测」。")
                                        .font(.system(size: 13))
                                        .foregroundColor(.secondary)
                                        .padding(.top, 40)
                                        .frame(maxWidth: .infinity)
                                } else {
                                    Text(rootReport)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(Color(red: 0.62, green: 0.62, blue: 0.68))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(14)
                                }
                            }
                            .background(Color.black)
                            .navigationTitle("权限检测报告")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .navigationBarLeading) {
                                    Button {
                                        UIPasteboard.general.string = rootReport
                                        showCopiedTip = true
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                                            showCopiedTip = false
                                        }
                                    } label: {
                                        Text(showCopiedTip ? "已复制" : "复制全部")
                                    }
                                    .disabled(rootReport.isEmpty)
                                }
                                ToolbarItem(placement: .navigationBarTrailing) {
                                    Button("重新检测") { runCapabilityProbe() }
                                        .disabled(rootReportRunning)
                                }
                            }
                        } label: {
                            HStack {
                                Text("权限检测报告")
                                Spacer()
                                Text(rootReport.isEmpty ? "未检测" : "已检测")
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
    }

    private func submitCommand() {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isExecuting else { return }

        // 诊断必须在**清空输入框之前**处理，否则读到的永远是空字符串。
        // 也刻意不走危险检查：这是排查工具，不是要执行的命令。
        if text == "ttdebug" || text.hasSuffix(" ttdebug") {
            handleDebugCommand(text)
            return
        }

        // 高危命令先拦一道
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

        // 一次性诊断在 submitCommand 里处理，不在这里。
        // 这里跑已经晚了：submitCommand 会先 `command = ""` 再调 execute，
        // 诊断读到的只会是空字符串——上一版就是这么白跑的。

        // 空行做视觉分隔；命令与状态各自显式标注类别，不靠解析文本
        transcript.append(TranscriptSegment(kind: .banner, text: ""))
        transcript.append(TranscriptSegment(kind: .command, text: "› \(text)"))
        transcript.append(TranscriptSegment(kind: .engineStatus, text: "[TT] 正在执行……"))
        isExecuting = true

        ShellCommandRunner.run(text) { result in
            DispatchQueue.main.async {
                transcript.append(contentsOf: TranscriptClassifier.classify(result))
                isExecuting = false
                // cd 之类可能改过当前目录，目录缓存与路径候选都得作废重来
                PathCompletion.invalidateCache()
                self.pathCompletions = []
            }
        }
    }

    /// 把补全链路的每一步中间值打出来，供真机核对。
    ///
    /// **接收任意一行，而不是直接读输入框。**
    /// 要查「刚打完空格那一刻」的状态，就必须能拿着当时的字符串重算一遍——
    /// 上一版就是死在这儿：诊断跑在 `command = ""` 之后，打出来全是空的，
    /// 等于什么都没查，用户白跑一趟。
    private func debugReport(for input: String) -> String {
        let parsed = InputParser.parse(input)
        let options = completions(for: parsed)
        var lines: [String] = ["TT_DEBUG_BEGIN"]
        lines.append("诊断对象=[\(input)] 字符数=\(input.count)")
        lines.append("末尾是空格=\(input.last.map { $0 == " " } ?? false)")
        lines.append("已完成的词 words=\(parsed.words)")
        lines.append("正在写的 token=[\(parsed.token)] 空=\(parsed.token.isEmpty)")
        let commandName = parsed.words.first ?? ""
        let matched = commandName.isEmpty ? nil : CommandManual.docs.first { $0.name == commandName }
        lines.append("命令名=[\(commandName)] 命中手册条目=\(matched?.name ?? "<无>")")
        if let matched = matched {
            lines.append("syntax=[\(matched.syntax)]")
            lines.append("optionList=\(matched.optionList.map { "\($0)" })")
        }
        lines.append("前面全是选项=\(parsed.words.dropFirst().allSatisfy { $0.hasPrefix("-") })")
        lines.append("命令/选项候选数=\(options.count)")
        for item in options {
            lines.append("  [\(item.kind.rawValue)] \(item.title)")
        }
        if input == command {
            lines.append("路径候选数=\(pathCompletions.count)")
            for item in pathCompletions.prefix(6) {
                lines.append("  [\(item.kind.rawValue)] \(item.title)")
            }
        } else {
            lines.append("路径候选：诊断对象不是当前输入框，跳过（路径要在后台列目录）")
        }
        lines.append("当前目录=\(FileManager.default.currentDirectoryPath)")
        lines.append("路径补全适用=\(PathCompletion.acceptsPath(commandName))")
        lines.append("执行中=\(isExecuting)")
        if !optionSnapshot.isEmpty {
            lines.append("最近一次自动自检：")
            lines.append("  " + optionSnapshot)
        }
        lines.append("渲染用 optionCompletions=\(optionCompletions.map { $0.title })")
        lines.append("渲染用 pathCompletions=\(pathCompletions.count) 条")
        lines.append("TT_DEBUG_END")
        return lines.joined(separator: "\n")
    }
    /// 一次 `ttdebug` 调用。两种写法：
    /// - 直接发 `ttdebug`                  → 诊断最近一次有内容的输入（快照）
    /// - 发 `ls ttdebug` / `mkdir ttdebug`  → 诊断 `ls ` / `mkdir `，不受快照影响
    ///
    /// 后者是关键：要观察「命令名 + 空格」那一刻的状态，就得把那串输入原样保留下来再发，
    /// 而发送按钮本来是要清空输入框的。两种写法都不清空输入，可以连着试。
    private func handleDebugCommand(_ text: String) {
        let suffix = " ttdebug"
        let probe: String
        if text.hasSuffix(suffix) {
            probe = String(text.dropLast(suffix.count))
        } else if text == "ttdebug" {
            probe = lastProbe
        } else {
            return
        }
        transcript.append(TranscriptSegment(kind: .banner, text: ""))
        transcript.append(TranscriptSegment(kind: .command, text: "› \(text)"))
        transcript.append(contentsOf: TranscriptClassifier.classify(debugReport(for: probe),
                                                                      fallback: .diagnostic))
        if probe != text {
            transcript.append(TranscriptSegment(kind: .engineStatus,
                                                text: "[TT] 上面诊断的是去掉「ttdebug」后的那一行"))
        }
    }

    /// 跑权限检测。
    ///
    /// 会真的建临时文件，所以放后台线程，而且**不能进启动自检**——
    /// 启动自检要快、要无副作用，这里是重活且会碰文件系统。
    private func runCapabilityProbe() {
        guard !rootReportRunning else { return }
        rootReportRunning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let report = CapabilityProbe.fullReport()
            DispatchQueue.main.async {
                self.rootReport = report
                self.rootReportRunning = false
            }
        }
    }
    private func runStartupDiagnostics() {
        guard !didRunDiagnostics else { return }
        didRunDiagnostics = true
        DispatchQueue.global(qos: .userInitiated).async {
            let report = EnvironmentProbe.fullReport()
            DispatchQueue.main.async {
                // 一次性输出完整报告。
                //
                // 之前是每 10ms 追加一行做瀑布流：每一行都要重建整份富文本、
                // 触发布局测量、再滚动一次，一秒上百次这种主线程循环
                // 在真机上直接把 App 压死。本版只去掉这一处，别的都不动。
                self.diagnosticReport = report
                let lineCount = report.split(separator: "\n", omittingEmptySubsequences: false).count
                self.transcript.append(TranscriptSegment(kind: .banner, text: ""))
                self.transcript.append(contentsOf: TranscriptClassifier.classify(report, fallback: .diagnostic))
                self.transcript.append(TranscriptSegment(kind: .success, text: "[TT] 启动自检完成 · \(lineCount) 行"))
                // 等输出排版完再弹键盘，否则键盘顶起来会盖住刚出来的末行
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.inputBridge.focus()
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

    // MARK: - 扩展键盘动作
    /// ↑↓ 翻历史。
    ///
    /// 只回填输入框、**不动光标位置**——按用户定的语义，↑↓ 管历史。
    /// `historyCursor` 为 nil 表示"不在翻历史中"，此时按 ↓ 不动。
    private func recallHistory(direction: Int) {
        guard !history.isEmpty else { return }
        if historyCursor == nil {
            guard direction < 0 else { return }
            historyCursor = history.count - 1
        } else if direction < 0 {
            guard historyCursor! > 0 else { return }
            historyCursor! -= 1
        } else {
            guard historyCursor! < history.count - 1 else {
                // 已经回到最底下（也就是这条之后没有更多了）→ 清空，回到"未翻"状态
                historyCursor = nil
                inputBridge.replaceWholeLine("")
                return
            }
            historyCursor! += 1
        }
        inputBridge.replaceWholeLine(history[historyCursor!])
    }
    /// ^C：清掉输入行；有命令在跑就把它杀掉。
    ///
    /// 杀的是 `posix_spawn` 出来的那个直接子进程。TT 的执行器不用 shell 管进程组
    /// （fork 在本机是坏的），所以只能杀最外层这一个——
    /// 单条命令下它就是命令本身，`&&` 链里只能杀掉当前这一段。
    private func cancelRunningCommand() {
        command = ""
        let pid = ProcessLauncher.takeCurrentPID()
        guard pid > 0 else {
            transcript.append(TranscriptSegment(kind: .engineStatus, text: "[TT] ^C：已清空输入，没有命令在执行"))
            return
        }
        kill(pid, SIGKILL)
        transcript.append(TranscriptSegment(kind: .engineStatus,
                                            text: "[TT] ^C：已终止正在执行的命令（pid \(pid)）"))
    }
    // MARK: - 命令自动补全

    /// 当前输入切成「已经写完的词」和「正在写的那一段」。
    ///
    /// **不依赖 `split(omittingEmptySubsequences: false)` 对尾部空段的处理。**
    /// `"ls "` 到底分出 `["ls", ""]` 还是 `["ls"]`，一旦行为和预期不符，
    /// 「刚打完命令名 → 该补选项」这条分支就永远进不去。
    /// 所以改成自己算：末尾有没有空格，决定最后一段算**已完成的词**
    /// 还是一个**刚开始写的空段**。判定表已用 PowerShell 移植验证 26/26，
    /// 且在 split 保留/丢弃尾部空段两种行为下结果完全一致。
    private var parsedInput: (words: [String], token: String) {
        InputParser.parse(command)
    }
    /// 补全条实际渲染的内容：**选项在前，路径在后**。
    /// 两者都是 onChange 算好写进来的显式状态，不是 body 里现算的。
    private var visibleCompletions: [Completion] {
        optionCompletions + pathCompletions
    }

    /// 算命令名/选项候选，并**顺手往终端打一行自检**。
    ///
    /// 「`ls ` 后面为什么不出 `-l`」这件事已经连查四版，四版都是靠读代码推断，
    /// 推错了三次——真机上到底算出了什么，从来没被观测过，
    /// 于是每次都以为是别的地方错了。这一版让程序自己开口：
    /// 只要它在「命令名 + 空格」状态下算出了选项，就往终端写一行，
    /// **用户什么都不用做**，随便发一条命令，答案就在屏幕上。
    private func computeOptionCompletions(for input: String) -> [Completion] {
        let options = completions(for: InputParser.parse(input))
        guard input.hasSuffix(" "), !options.isEmpty else { return options }
        let titles = options.map { $0.title }.joined(separator: " ")
        let line = "[TT] 候选自检：[\(input)] → 算出 \(options.count) 个选项：\(titles)"
        // 同一状态不重复刷屏
        guard line != optionSnapshot else { return options }
        optionSnapshot = line
        transcript.append(TranscriptSegment(kind: .engineStatus, text: line))
        return options
    }

    /// 候选：正在写命令名时补命令名；进入参数部分后补这条命令的选项。
    private func completions(for parsed: (words: [String], token: String)) -> [Completion] {
        let commandName = parsed.words.first ?? ""
        let token = parsed.token

        // —— 还在写命令名 ——
        guard commandName.isEmpty else {
            // —— 已经进入参数部分：补这条命令自己的选项 ——
            // 两种形态都补：token 为空（刚打完一个词）或以 `-` 开头（正在补选项）。
            // 空那段也要补，是因为选项和路径应该并排摆出来让用户挑——
            // 只给路径的话，想加 `-l` 就得先自己敲个横杠。
            guard token.isEmpty || token.hasPrefix("-"),
                  let doc = CommandManual.docs.first(where: { $0.name == commandName })
            else { return [] }
            // 已经打过真正的参数（非选项的那种词）就不再打扰，避免刷屏
            guard !parsed.words.dropFirst().contains(where: { !$0.hasPrefix("-") })
            else { return [] }
            return doc.optionList
                .filter { token.isEmpty || token == "-" || $0.hasPrefix(token) }
                .map { Completion(kind: .option, title: $0, detail: "", isExact: $0 == token) }
        }

        let needle = token.lowercased()
        guard !needle.isEmpty else { return [] }
        let prefixHits = CommandManual.docs.filter { $0.name.lowercased().hasPrefix(needle) }
        // 只记得中间几个字母时也搜得到
        let looseHits = CommandManual.docs.filter {
            !$0.name.lowercased().hasPrefix(needle) && $0.name.lowercased().contains(needle)
        }
        return (prefixHits + looseHits).prefix(12).map { doc in
            Completion(kind: .command,
                        title: doc.name,
                        detail: doc.syntax,
                        isExact: doc.name.lowercased() == needle)
        }
    }
    /// 点候选。
    ///
    /// 命令名一律补空格、不再自动塞横杠——选项改成候选摆出来让人点，
    /// 塞横杠等于替用户做了「我要加选项」的决定，而 `ls` 后面跟路径同样常见。
    private func applyCompletion(_ candidate: Completion) {
        let leading = command.prefix(while: { $0 == " " || $0 == "\t" }).count
        let indent = String(repeating: " ", count: leading)
        let parsed = parsedInput
        let head = parsed.words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        switch candidate.kind {
        case .path:
            // 路径候选自带完整前缀，直接替换光标所在的那一段。
            // 此时如果上一段是个孤零零的 `-`（用户跳过了选项直接点路径），
            // 它会被一起丢掉，不会留下 `ls - /etc/` 这种错的东西。
            command = indent + head + (head.isEmpty ? "" : " ") + candidate.title
        case .command:
            command = indent + candidate.title + " "
        case .option:
            // 前面那些已完成的词照留，本段换成选中项 + 空格：
            //   ls 空格   点 -l → ls -l
            //   ls -      点 -l → ls -l        （替换掉那个孤零零的横杠）
            //   ls -l 空格 点 -a → ls -l -a     （叠第二个选项）
            command = indent + (head.isEmpty ? "" : head + " ") + candidate.title + " "
        }
    }

    /// 路径补全走后台：列目录是 I/O，不能在 body 里算。
    /// 防抖 120ms，连着打字时不会每键扫一次盘。
    private func refreshPathCompletions() {
        pathCompletions = []
        let parsed = parsedInput
        let commandName = parsed.words.first ?? ""
        // 还在写命令名时不补路径：那时补的是命令名，路径出来只会打架
        guard !commandName.isEmpty, PathCompletion.acceptsPath(commandName) else { return }
        let token = parsed.token
        let cwd = FileManager.default.currentDirectoryPath
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.12) {
            let found = PathCompletion.candidates(commandName: commandName, token: token, cwd: cwd)
            DispatchQueue.main.async {
                // 期间用户可能已经改输入或转去补命令名，过期结果直接丢
                guard self.parsedInput.token == token else { return }
                self.pathCompletions = found
            }
        }
    }

    // MARK: - 命令手册

    private func persistManual() {
        ManualStore.save(manualEntries)
    }

    /// 手册里点一条。单条命令直接执行，脚本按它自己的跑法处理。
    ///
    /// 危险命令的拦截和输入框走同一条路——手册绝不绕过检查。
    private func runManualEntry(_ entry: ManualEntry) {
        if entry.isScript {
            let count = entry.highestArgumentIndex
            if count > 0 {
                scriptArguments = Array(repeating: "", count: count)
                scriptAwaitingArguments = entry
            } else {
                showManual = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    launchScript(entry, arguments: [])
                }
            }
            return
        }
        let text = entry.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        showManual = false
        // 等面板收起再执行，避免和 sheet 转场动画抢状态
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if let hit = DangerGuard.evaluate(text) {
                pendingDangerCommand = text
                pendingDanger = hit
            } else {
                execute(text)
            }
        }
    }

    private func launchScript(_ entry: ManualEntry, arguments: [String]) {
        // 整段脚本先按整体过一遍危险检查：一旦有问题就整段不跑，不存在"先跑一半再拦"的中间态
        if let hit = DangerGuard.evaluate(entry.body) {
            pendingDangerScript = entry
            pendingScriptArguments = arguments
            pendingDangerCommand = entry.displayName
            pendingDanger = hit
            return
        }

        transcript.append(TranscriptSegment(kind: .banner, text: ""))
        transcript.append(TranscriptSegment(kind: .engineStatus, text: "[TT] 正在执行脚本……"))
        isExecuting = true

        if entry.scriptMode == .mksh {
            ShellCommandRunner.runScript(entry.body, arguments: arguments) { result in
                DispatchQueue.main.async {
                    self.transcript.append(contentsOf: TranscriptClassifier.classify(result))
                    self.finishScript()
                }
            }
        } else {
            let lines = entry.body
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0) }
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            runScriptLines(lines, arguments: arguments, index: 0)
        }
    }

    /// 逐行执行：一行跑完再跑下一行，中间 TT 的当前目录状态得以保留，
    /// 所以脚本里的 cd 对后面的行有效，echo / pwd 这类内建也照常工作。
    private func runScriptLines(_ lines: [String], arguments: [String], index: Int) {
        guard index < lines.count else {
            finishScript()
            return
        }
        let expanded = expandArguments(lines[index], arguments)
        guard !expanded.trimmingCharacters(in: .whitespaces).isEmpty else {
            runScriptLines(lines, arguments: arguments, index: index + 1)
            return
        }
        transcript.append(TranscriptSegment(kind: .command, text: "› \(expanded)"))
        ShellCommandRunner.run(expanded) { result in
            DispatchQueue.main.async {
                self.transcript.append(contentsOf: TranscriptClassifier.classify(result))
                self.runScriptLines(lines, arguments: arguments, index: index + 1)
            }
        }
    }

    private func finishScript() {
        isExecuting = false
        PathCompletion.invalidateCache()
        pathCompletions = []
    }

    /// 把 $1…$9 换成实际参数。
    ///
    /// 只在逐行模式下需要：整段交给 mksh 时位置参数由 mksh 自己处理。
    /// 替换值一律加单引号，否则路径里的空格会把命令拆成两条。
    private func expandArguments(_ text: String, _ arguments: [String]) -> String {
        guard !arguments.isEmpty else { return text }
        var out = ""
        var rest = Substring(text)
        while let dollar = rest.firstIndex(of: "$") {
            out += rest[rest.startIndex..<dollar]
            let after = rest.index(after: dollar)
            guard after < rest.endIndex, rest[after].isNumber else {
                // $$、$#、变量名之类原样保留
                out += "$"
                rest = rest[after...]
                continue
            }
            let digits = rest[after...].prefix { $0.isNumber }
            let position = (Int(digits) ?? 0) - 1
            if position >= 0, position < arguments.count {
                out += "'\(arguments[position])'"
            }
            rest = rest[rest.index(after, offsetBy: digits.count)...]
        }
        out += rest
        return out
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
///
/// Every call is **bounded**: a child that outruns `timeoutSeconds` gets SIGKILLed and
/// the timeout is written into the output. Without that bound, `rm -rf /` walks the entire
/// iOS filesystem — as uid 501 it deletes nothing, but it still lstats every single entry —
/// and the send arrow spins for minutes with no way out.
private enum ProcessLauncher {
    /// 默认上限。够跑完 `sleep 60` 和常规的文件遍历，又不至于让人干等。
    /// 默认上限。够跑完 `sleep 60` 和常规的文件遍历，又不至于让人干等。
    static let defaultTimeoutSeconds = 60
    private static let pidLock = NSLock()
    private static var _currentPID: pid_t = 0
    /// 正在跑的子进程 pid，供 ^C 取消用。0 表示没有。
    static var currentPID: pid_t {
        pidLock.lock()
        defer { pidLock.unlock() }
        return _currentPID
    }
    /// 取出并清空当前 pid。^C 走这个：取出即认领，避免连点两次杀到新起的命令上。
    static func takeCurrentPID() -> pid_t {
        pidLock.lock()
        defer { pidLock.unlock() }
        let pid = _currentPID
        _currentPID = 0
        return pid
    }
    private static func setCurrentPID(_ pid: pid_t) {
        pidLock.lock()
        _currentPID = pid
        pidLock.unlock()
    }

    static func spawnCapturing(path: String,
                               arguments: [String],
                               environment: [String: String]? = nil,
                               stdinData: Data? = nil,
                               timeoutSeconds: Int = defaultTimeoutSeconds) -> SpawnResult {
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
        } else {
            // **没有管道输入时，把 stdin 接到 /dev/null。**
            //
            // 否则子进程继承 TT 自己那个 stdin——图形 App 的这个 fd 到底连着什么，
            // 平台说了算，说不好就是阻塞的。一旦阻塞，任何「不带文件参数就读 stdin」
            // 的命令都会永久挂住：cat / wc / base64 / xxd / tee / grep。
            //
            // 真机踩过：`base64 hello`（不带文件名）→ 卡死，App 停在「正在执行」，
            // 输入框不响应、**补全候选条也不弹**——外观看像补全功能坏了。
            //
            // 接 /dev/null 之后读操作立刻返回 EOF，行为等同于真 shell 里按 Ctrl-D。
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
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
        // 登记 pid，^C 靠它找得到正在跑的那个进程
        setCurrentPID(childPID)

        // 有界等待：用 poll 带截止时间，而不是阻塞 read。
        //
        // 阻塞 read 要一直等到子进程关掉管道写端；子进程要是永远不退出，这里就永远不返回，
        // 表现就是发送箭头一直转、界面锁死。用 poll 定期看一眼截止时间，超时就 kill。
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var timedOut = false
        let deadline = DispatchTime.now() + .seconds(timeoutSeconds)
        var watchFD = pollfd(fd: pipeFDs[0], events: Int16(POLLIN), revents: 0)
        while true {
            if DispatchTime.now() >= deadline {
                timedOut = true
                kill(childPID, SIGKILL)
                break
            }
            let ready = poll(&watchFD, 1, 200)
            if ready > 0 {
                let bytesRead = read(pipeFDs[0], &buffer, buffer.count)
                if bytesRead > 0 {
                    output.append(contentsOf: buffer[0..<bytesRead])
                } else if bytesRead == 0 {
                    break                                   // 管道关闭，子进程已退出
                } else if errno != EINTR {
                    break
                }
            } else if ready == 0 {
                continue                                    // 暂时没数据，接着等
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
        setCurrentPID(0)   // 已经收尸了，pid 作废
        let exitCode: Int32 = waitResult == childPID
            ? ((waitStatus & 0x7f) == 0 ? ((waitStatus >> 8) & 0xff) : 128 + (waitStatus & 0x7f))
            : -1
        var text = String(decoding: output, as: UTF8.self)
        if timedOut {
            let note = "[TT] 命令超过 \(timeoutSeconds) 秒仍未结束，已强制终止。\n"
            text = text.isEmpty ? note : text + "\n" + note
        }
        return SpawnResult(spawnErrno: 0, exitCode: exitCode, output: text)
    }
}

/// Executes commands through the device's /bin/sh and returns real stdout/stderr.
/// Splits a command line into segments joined by shell operators.
/// mksh on this device SIGBUSes when it forks more than once, so pipelines and
/// `&&` chains are split by the app and each segment runs as its own single
/// command; `|` is honored by piping the previous segment's stdout into the
/// next segment's stdin.

/// 判断一行是不是 shell 控制流（`for` / `if` / `while` / `until` / `case` / `{ }` 块）。
///
/// ### 为什么必须单独判
///
/// 分段执行按 `;` `|` `&&` `||` 切。这一行：
/// ```
/// for i in 1 2 3; do echo $i; done
/// ```
/// 会被切成 `for i in 1 2 3` / `do echo $i` / `done` 三段，
/// 三段全是废的——`for i in 1 2 3` 不是命令，`done` 也不是。
/// 控制流必须**整段**交给 mksh，拆了就报废。
///
/// ### 为什么不用自己实现循环
///
/// mksh 自己是完整的 shell，`for` `if` `while` `case` 全是它的**原生语法**，
/// 一个都不用我们写。App 层要做的只是「别把它切开」。
///
/// ### 判定只看引号外的独立词
///
/// `echo "do not do that"` 不是控制流，引号里的 `do` 不算数。
///
/// ### 宁可误判
///
/// 误判成控制流 = 整段丢给 mksh，对普通命令**也是对的**（mksh 本来就能跑），
/// 最坏只丢掉 TT 自己的 cwd 跟踪。反过来漏判，那条命令直接报废。
private enum ControlFlowDetector {
    /// 开头的关键字，出现任意一个就足以判定。
    private static let openers: Set<String> = ["for", "if", "while", "until", "case", "select"]
    /// 收尾的关键字。`ls do` 这种误判无害，`for … done` 少了它就漏判。
    private static let closers: Set<String> = ["do", "done", "then", "fi", "elif", "else", "esac"]

    static func isControlFlow(_ line: String) -> Bool {
        for word in words(in: line) {
            let lower = word.lowercased()
            if openers.contains(lower) || closers.contains(lower) {
                return true
            }
        }
        return false
    }

    /// 这一行是不是**必须整段**交给 mksh，不能被拆。
    ///
    /// 两种情形：
    /// 1. 控制流——`;` 会把 `for … done` 切烂。
    /// 2. **变量赋值 + 后面还有段**——分段执行是「每段单独起一个 mksh 进程」，
    ///    赋值死在第一个进程里，后面拿到的是空变量。
    ///    实测：`x=10; echo $((x*2)) 和 ${x} 和 ${#x}` → `0 和  和 0`。
    ///
    /// 注意**不**管 `cd`：TT 需要在本进程内拦下 cd 才能跨命令保持目录，
    /// 那一条仍然走分段路径。
    static func needsWholeLine(_ line: String) -> Bool {
        if isControlFlow(line) { return true }
        return hasStatefulAssignment(line)
    }

    /// 顶层（引号外）有分段符吗。
    ///
    /// 没分段符的话整行本来就是一个段，走哪条路都一样，
    /// 就不必为 `x=10` 这种孤立的赋值改走整段了。
    private static func hasTopLevelSeparator(_ line: String) -> Bool {
        var quote: Character?
        for character in line {
            if let active = quote {
                if character == active { quote = nil }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            if character == ";" || character == "|" || character == "&" { return true }
        }
        return false
    }

    /// 一个词是不是变量赋值：`x=10`、`X=1`、`_foo=bar`。
    /// `export X=1` 也能命中，因为拆完词之后 `X=1` 自己也在列。
    private static func isAssignment(_ word: String) -> Bool {
        let lower = word.lowercased()
        guard let first = lower.first, (first >= "a" && first <= "z") || first == "_" else {
            return false
        }
        // 首字符之后只允许字母数字下划线，然后必须紧跟等号
        for character in lower.dropFirst() {
            if (character >= "a" && character <= "z") || (character >= "0" && character <= "9") || character == "_" {
                continue
            }
            return false
        }
        return word.contains("=")
    }

    private static func hasStatefulAssignment(_ line: String) -> Bool {
        guard hasTopLevelSeparator(line) else { return false }
        for word in words(in: line) {
            if isAssignment(word) { return true }
        }
        return false
    }

    /// 按空白和分隔符切词，**引号内的内容整段跳过**。
    ///
    /// 分隔符包含 `;` `|` `&`，所以 `do;` 切出来是 `do` 而不是 `do;`。
    /// 不切这两类符号的话，`then` 后面粘着分隔符就匹配不上关键字表了。
    static func words(in line: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?

        func flush() {
            if !current.isEmpty {
                result.append(current)
                current = ""
            }
        }

        for character in line {
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                }
                continue                      // 引号里的词不参与判定
            }
            if character == "\"" || character == "'" {
                quote = character
                flush()
                continue
            }
            if character.isWhitespace || character == ";" || character == "|"
                || character == "&" || character == "(" || character == ")" {
                flush()
                continue
            }
            current.append(character)
        }
        flush()
        return result
    }
}

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
    /// 整段脚本原样交给内置 mksh。**控制流和「整段 mksh」脚本模式走的是同一条路。**
    ///
    /// 好处是拿到完整 shell 语义：for、if、while、变量、函数都能用。
    /// 代价有一个，调用前必须知情：
    /// 脚本里的 `cd` 发生在 mksh 自己的进程里，**不会**更新 TT 记住的当前目录。
    /// 至于 fork——本机 fork 是 SIGBUS 的，但**只有循环体跑外部命令时才会踩到**，
    /// 跑内建命令的循环体一次 fork 都不需要。踩到了 `runWholeLine` 会给明确报错。
    static func runScript(_ script: String, arguments: [String], completion: @escaping (String) -> Void) {
        runWholeLine(script,
                     header: "[TT] 执行方式：整段 mksh（脚本里的 cd 不改变 TT 当前目录）",
                     arguments: ["ttscript"] + arguments,
                     completion: completion)
    }

    /// 控制流整段执行。
    ///
    /// 为什么不能走分段：`;` 就是分段符，
    /// `for i in 1 2 3; do echo $i; done` 会被切成三段废命令。
    /// 带变量赋值的行同理——赋值死在第一个 mksh 进程里。
    /// 现在都由 `needsWholeLine` 统一判断、`runWholeLine` 统一执行。

    /// 共用实现：把一整段原样丢给内置 mksh 跑一次。
    private static func runWholeLine(_ script: String,
                                     header: String,
                                     arguments: [String],
                                     completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let mkshPath = (Bundle.main.bundlePath as NSString).appendingPathComponent("ttbin/mksh")
            let binPath = (Bundle.main.bundlePath as NSString).appendingPathComponent("ttbin")
            let environment = ["PATH": "\(binPath):/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "dumb"]
            // `mksh -c 脚本 $0 $1 $2 …`：第一个非选项参数是 $0，位置参数从 $1 起算，
            // 所以这里要把一个占位名放在用户参数前面。
            let result = ProcessLauncher.spawnCapturing(
                path: mkshPath,
                arguments: ["-c", script] + arguments,
                environment: environment)

            var lines: [String] = [header]
            if !result.output.isEmpty {
                lines.append(result.output)
            }
            if result.spawnErrno != 0 {
                lines.append("[TT] 创建进程失败：\(String(cString: strerror(result.spawnErrno)))（errno \(result.spawnErrno)）")
            } else if result.exitCode > 128 {
                lines.append(contentsOf: signalExplanation(exitCode: result.exitCode))
            } else {
                lines.append("[TT] 退出码：\(result.exitCode)")
            }
            completion(lines.joined(separator: "\n"))
        }
    }

    /// mksh 被信号打死时的说明。
    ///
    /// `spawnCapturing` 把「被信号 N 打死」编码成退出码 `128 + N`，
    /// 所以 SIGBUS(10) 会看到 138。这个区分很重要：
    /// **退出码非零 ≠ 脚本报错**，很可能是 fork 把 mksh 打死了。
    private static func signalExplanation(exitCode: Int32) -> [String] {
        let signalNumber = exitCode - 128
        var lines = ["", "[TT] mksh 被信号 \(signalNumber) 终止。"]
        if signalNumber == 10 {
            lines.append("     本机 fork() 不可用（SIGBUS），而 mksh 跑外部命令必须 fork。")
            lines.append("     只用内建命令的循环体不受影响：")
            lines.append("       for i in 1 2 3; do echo $i; done     ← 能跑")
            lines.append("       for i in 1 2 3; do seq $i; done      ← 循环体跑外部命令，跑不了")
            lines.append("     if 同理：`[ -f /etc/hosts ] && echo 有` 里两边都得是内建。")
        } else {
            lines.append("     这不是脚本写错，是 mksh 自己被系统杀掉了。")
            lines.append("     换简单点的写法再试一次。")
        }
        return lines
    }

    static func run(_ command: String, completion: @escaping (String) -> Void) {
        // 控制流**和带变量赋值的行**都走整段，别往下掉进分段执行。
        // 判据在 ControlFlowDetector 的注释里：`;` 会把 for/if 切烂，
        // 也会让 `x=5` 死在第一个进程里、后面的段拿到空变量。
        if ControlFlowDetector.needsWholeLine(command) {
            let isControl = ControlFlowDetector.isControlFlow(command)
            runWholeLine(command,
                         header: isControl
                           ? "[TT] 控制流：整段交给内置 mksh（脚本里的 cd 不改变 TT 当前目录）"
                           : "[TT] 变量状态：整段交给内置 mksh（分段执行会让赋值死在第一个进程里）",
                         arguments: ["ttcf"],
                         completion: completion)
            return
        }

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

/// 权限与能力检测。
///
/// 目的是把「这台机器上 TT 到底能碰到什么」一次性测清楚，不靠猜。
/// 其中**写测试会真的建文件**：用一个唯一命名的临时文件，建完立刻删掉，
/// 只删自己刚建的那一个，绝不碰任何已有数据。这是唯一能真正测出写权限的办法——
/// `access(W_OK)` 会骗人，它不看 ACL 也不看 entitlement 的实际效果。
private enum CapabilityProbe {

    /// 要逐一测读写执行的路径。挑的是「出事了最要命」的那几个。
    private static let probePaths = [
        "/", "/etc", "/private", "/var", "/var/mobile",
        "/var/mobile/Library", "/var/mobile/Media", "/private/var/mobile",
        "/var/tmp", "/tmp", "/usr", "/usr/bin", "/bin", "/sbin",
        "/lib", "/System", "/Applications", "/Library"
    ]

    /// 越狱痕迹。有这些通常意味着存在 root 设施。
    private static let jailbreakMarkers = [
        "/var/jb", "/private/var/jb", "/usr/libexec", "/bin/bash",
        "/etc/apt", "/Library/MobileSubstrate", "/usr/sbin/sshd",
        "/Applications/Cydia.app", "/usr/bin/ssh", "/bin/zsh"
    ]

    private static let binaryDirs = ["/bin", "/usr/bin", "/sbin", "/usr/sbin", "/usr/libexec"]

    // MARK: - 各项探测

    private static func identity() -> [String] {
        var lines: [String] = []
        let uid = getuid(), euid = geteuid(), gid = getgid(), egid = getegid()
        var user = "\(uid)"
        var group = "\(gid)"
        if let pw = getpwuid(euid), let n = pw.pointee.pw_name { user = String(cString: n) }
        if let gr = getgrgid(egid), let n = gr.pointee.gr_name { group = String(cString: n) }
        lines.append("uid=\(uid) euid=\(euid) gid=\(gid) egid=\(egid)")
        lines.append("用户名=\(user)  组名=\(group)")
        lines.append("是否 root=\(euid == 0 ? "是" : "否")")
        lines.append("注意：root 与否不等于能碰到什么，下面才是实测结果")
        return lines
    }

    /// 真的建一个文件再删掉，返回 true 表示写得动
    private static func writeProbe(_ directory: String) -> Bool {
        let name = ".tt-cap-\(UUID().uuidString)"
        let path = (directory as NSString).appendingPathComponent(name)
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600)
        guard fd >= 0 else { return false }
        _ = write(fd, "tt", 2)
        close(fd)
        unlink(path)
        return true
    }

    /// 补齐到固定宽度，替掉 printf 的 %-Ns（那条路要传 C 字符串指针，容易踩坑）
    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    private static func paths() -> [String] {
        var lines: [String] = [pad("路径", 26) + pad("读", 8) + pad("写", 8) + "执行"]
        for path in probePaths {
            let readable = FileManager.default.fileExists(atPath: path)
                && (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
            let writable = writeProbe(path)
            let executable = access(path, X_OK) == 0
            lines.append(pad(path, 26) + pad(readable ? "可" : "不可", 8)
                         + pad(writable ? "可" : "不可", 8) + (executable ? "可" : "不可"))
        }
        return lines
    }

    /// 写得动的地方单独拎出来——这几条才是真正要盯的
    private static func writableSummary() -> [String] {
        var lines: [String] = []
        for path in probePaths where writeProbe(path) {
            lines.append("  可写：\(path)")
        }
        if lines.isEmpty { lines.append("  （没有一项写得动）") }
        return lines
    }

    private static func jailbreak() -> [String] {
        var lines: [String] = []
        var found = 0
        for path in jailbreakMarkers {
            let exists = FileManager.default.fileExists(atPath: path)
            if exists { found += 1 }
            lines.append("  \(exists ? "有" : "无")  \(path)")
        }
        lines.append(found == 0 ? "结论：未发现越狱痕迹" : "结论：发现 \(found) 项越狱痕迹")
        return lines
    }

    /// 系统自带的可执行文件。有 root 设施的话这里会明显变长。
    private static func systemBinaries() -> [String] {
        var lines: [String] = []
        var total = 0
        for dir in binaryDirs {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            let runnable = names.filter { name in
                access((dir as NSString).appendingPathComponent(name), X_OK) == 0
            }.sorted()
            total += runnable.count
            if runnable.isEmpty {
                lines.append("  \(dir)：无可执行文件")
            } else {
                lines.append("  \(dir)（\(runnable.count) 个）：\(runnable.prefix(24).joined(separator: " "))")
                if runnable.count > 24 { lines.append("      …… 还有 \(runnable.count - 24) 个") }
            }
        }
        lines.append("合计 \(total) 个系统可执行文件")
        return lines
    }

    private static func path() -> [String] {
        let env = ProcessInfo.processInfo.environment
        return ["PATH=\(env["PATH"] ?? "(未设置)")"]
    }

    /// 进程创建能力。fork 坏了但 posix_spawn 能用——这正是 TT 架构的地基。
    private static func processCapability() -> [String] {
        var lines: [String] = []
        let mkshPath = (Bundle.main.bundlePath as NSString).appendingPathComponent("ttbin/mksh")
        let binPath = (Bundle.main.bundlePath as NSString).appendingPathComponent("ttbin")
        let environment = ["PATH": "\(binPath):/usr/bin:/bin", "TERM": "dumb"]

        let spawnMksh = ProcessLauncher.spawnCapturing(path: mkshPath,
                                                      arguments: ["-c", "exit 0"],
                                                      environment: environment)
        lines.append("posix_spawn 内置 mksh：\(spawnMksh.exitCode == 0 ? "可用" : "不可用（退出码 \(spawnMksh.exitCode)）")")

        // mksh 能不能把单条外部命令 exec 掉——不 fork 的那条路
        let spawnExternal = ProcessLauncher.spawnCapturing(path: mkshPath,
                                                          arguments: ["-c", "\(binPath)/whoami"],
                                                          environment: environment)
        let externalText = spawnExternal.output.trimmingCharacters(in: .newlines)
        lines.append("mksh 执行外部命令：\(spawnExternal.exitCode == 0 ? "可用" : "不可用（退出码 \(spawnExternal.exitCode)）")")
        if !externalText.isEmpty { lines.append("  输出：\(externalText)") }

        let forkPath = (binPath as NSString).appendingPathComponent("ttfork")
        let probePath = (Bundle.main.bundlePath as NSString).appendingPathComponent("ttprobe")
        if FileManager.default.isExecutableFile(atPath: forkPath) {
            let forkResult = ProcessLauncher.spawnCapturing(path: forkPath,
                                                            arguments: [probePath, "8"],
                                                            environment: environment)
            let text = forkResult.output
            if text.contains("BROKEN:signal") {
                lines.append("fork：不可用（被信号终止，典型 SIGBUS）")
            } else if text.contains("BROKEN:fork") {
                lines.append("fork：不可用（fork() 本身失败）")
            } else if text.contains("ALL_OK") {
                lines.append("fork：可用")
            } else {
                lines.append("fork：结论不明（探针无输出）")
            }
        } else {
            lines.append("fork：探针未随包提供")
        }
        lines.append("说明：fork 不可用时，for / if / 管道 / 重定向都得由 App 自己拆开逐段执行")
        return lines
    }

    private static func device() -> [String] {
        var lines: [String] = []
        lines.append("系统=\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
        lines.append("机型=\(UIDevice.current.model)")
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/")
        if let a = attrs, let free = a[.systemFreeSize] as? Int64,
           let total = a[.systemSize] as? Int64 {
            lines.append("磁盘：剩余 \(free / 1024 / 1024 / 1024) GB / 共 \(total / 1024 / 1024 / 1024) GB")
        }
        return lines
    }

    // MARK: - 汇总

    static func fullReport() -> String {
        var lines: [String] = ["[TT] ── 权限检测报告 ──"]
        lines.append("")
        lines.append("【身份】")
        lines.append(contentsOf: identity())
        lines.append("")
        lines.append("【目录读写实测】")
        lines.append(contentsOf: paths())
        lines.append("")
        lines.append("【写得动的地方】")
        lines.append(contentsOf: writableSummary())
        lines.append("")
        lines.append("【越狱痕迹】")
        lines.append(contentsOf: jailbreak())
        lines.append("")
        lines.append("【系统可执行文件】")
        lines.append(contentsOf: systemBinaries())
        lines.append("")
        lines.append("【进程创建能力】")
        lines.append(contentsOf: processCapability())
        lines.append("")
        lines.append("【PATH】")
        lines.append(contentsOf: path())
        lines.append("")
        lines.append("【设备】")
        lines.append(contentsOf: device())
        lines.append("")
        lines.append("TT_ROOT_REPORT_END")
        return lines.joined(separator: "\n")
    }
}

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
