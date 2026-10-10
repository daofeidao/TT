import SwiftUI
import UIKit
import Darwin

private let ttAppVersion: String = {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.2"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    return "v\(version) (b\(build))"
}()

struct ContentView: View {
    @State private var command = ""
    @State private var transcript = """
    TT 终端 · \(ttAppVersion)
    文字长按可选择与复制。
    命令由应用内置 mksh Shell 真实执行（系统不含 /bin/sh）；启动失败时自动降级内置解释器。
    """
    @State private var history: [String] = []
    @State private var showHistory = false
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
                    SelectableTerminalTextView(text: $transcript)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("transcript")
                }
                .background(Color.black)
                .onChange(of: transcript) { _ in
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
    }

    private func submitCommand() {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isExecuting else { return }

        history.append(text)
        if history.count > 50 {
            history.removeFirst(history.count - 50)
        }
        command = ""

        if text == "clear" {
            clearTranscript()
            return
        }

        transcript += "\n\n› \(text)\n[TT] 正在执行……"
        isExecuting = true

        ShellCommandRunner.run(text) { result in
            DispatchQueue.main.async {
                transcript += "\n\(result)"
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
                transcript += "\n\n" + report
            }
        }
    }

    private func copyAll() {
        UIPasteboard.general.string = transcript
    }

    private func clearTranscript() {
        transcript = "TT 终端已清空。\n输入 help 查看内置解释器支持的命令。"
    }
}

/// UITextView provides native iOS long-press selection handles and the Copy menu.
private struct SelectableTerminalTextView: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> SelectableTerminalUITextView {
        let view = SelectableTerminalUITextView()
        view.backgroundColor = .clear
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.textContainerInset = UIEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        view.textContainer.lineFragmentPadding = 0
        view.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        view.textColor = UIColor(red: 0.76, green: 0.96, blue: 0.78, alpha: 1)
        view.tintColor = .green
        view.text = text
        view.accessibilityIdentifier = "tt.terminal.text"
        return view
    }

    func updateUIView(_ uiView: SelectableTerminalUITextView, context: Context) {
        guard uiView.text != text else { return }
        let selectionWasAtEnd = uiView.selectedRange.location >= (uiView.text as NSString).length
        uiView.text = text
        if selectionWasAtEnd {
            uiView.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
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
        let text: String
        let separatorAfter: String  // what connects this segment to the next one
    }

    static func split(_ input: String) -> [Segment] {
        var result: [Segment] = []
        var current = ""
        var quote: Character?

        func finish(with separator: String) {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                result.append(Segment(text: trimmed, separatorAfter: separator))
            }
            current = ""
        }

        var index = input.startIndex
        while index < input.endIndex {
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

/// Executes commands through the bundled mksh and returns real stdout/stderr.
/// iOS may reject process creation (EPERM, seen on the v0.3.0 device test); then the
/// full failure record is printed and the command falls back to the built-in
/// interpreter. Every result states which engine produced it. No echo-faking.
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

                let result = ProcessLauncher.spawnCapturing(
                    path: mkshPath,
                    arguments: ["-c", segment.text],
                    environment: environment,
                    stdinData: receivesPipeInput ? pipedInput : nil
                )
                if result.spawnErrno != 0 {
                    outputLines.append(failureRecord(path: mkshPath, spawnErrno: result.spawnErrno))
                    failedToSpawn = true
                    break
                }
                let text = result.output.trimmingCharacters(in: .newlines)
                if !text.isEmpty {
                    outputLines.append(text)
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
        } else {
            lines.append("[TT] fork 探针：ttfork 未随包提供")
        }

        lines.append("[TT] 结论：\(conclusion(binsh: binshResult, mksh: mkshResult, probe: probe))")
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
            let mark = executable ? "*" : "!" + String(size) + "B"
            let entMark = signed ? "+" : "-ent"
            parts.append(name + mark + entMark)
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

    private static func conclusion(binsh: SpawnResult, mksh: SpawnResult, probe: SpawnResult) -> String {
        switch (mksh.spawnErrno == 0, binsh.spawnErrno == 0) {
        case (true, true):
            return "内置 mksh 与系统 /bin/sh 均可启动——命令由内置 mksh 执行（完整 shell 语义：管道/重定向/&&）。"
        case (true, false):
            return "内置 mksh 可启动——命令由真实 Shell 执行；系统 /bin/sh 不存在或被拒（\(probe.spawnErrno == 0 ? "容器内程序也可启动" : "容器内探针仍被拒：属预期外，欢迎反馈")）。"
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
