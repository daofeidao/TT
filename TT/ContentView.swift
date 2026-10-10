import SwiftUI
import UIKit
import Darwin

struct ContentView: View {
    @State private var command = ""
    @State private var transcript = """
    TT 终端 · 第三版测试
    文字选择与 Shell 命令执行测试。
    建议依次运行：pwd、ls、whoami、uname -a、date。
    """
    @State private var history: [String] = []
    @State private var showHistory = false
    @State private var isExecuting = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(isExecuting ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)

                Text("TT 终端")
                    .font(.headline.monospaced())

                Text("第三版测试")
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

        transcript += "\n\n› \(text)\n[TT] 正在执行……"
        command = ""
        isExecuting = true

        ShellCommandRunner.run(text) { result in
            DispatchQueue.main.async {
                transcript += "\n\(result)"
                isExecuting = false
            }
        }
    }

    private func clearTranscript() {
        transcript = "TT 终端已清空。\n输入 pwd、ls、whoami、uname -a 或 date 测试命令执行。"
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

/// Executes commands through the device's /bin/sh and returns real stdout/stderr.
/// iOS sandbox or system policy may reject process creation; that error is shown explicitly.
private enum ShellCommandRunner {
    static func run(_ command: String, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var pipeFDs: [Int32] = [0, 0]
            guard pipe(&pipeFDs) == 0 else {
                completion("[TT] 创建输出管道失败：\(String(cString: strerror(errno)))")
                return
            }

            var actions: posix_spawn_file_actions_t?
            let actionsStatus = posix_spawn_file_actions_init(&actions)
            guard actionsStatus == 0, let spawnActions = actions else {
                close(pipeFDs[0])
                close(pipeFDs[1])
                completion("[TT] 初始化 Shell 启动参数失败：\(String(cString: strerror(actionsStatus)))")
                return
            }
            posix_spawn_file_actions_adddup2(spawnActions, pipeFDs[1], STDOUT_FILENO)
            posix_spawn_file_actions_adddup2(spawnActions, pipeFDs[1], STDERR_FILENO)
            posix_spawn_file_actions_addclose(spawnActions, pipeFDs[0])
            posix_spawn_file_actions_addclose(spawnActions, pipeFDs[1])

            var childPID: pid_t = 0
            let spawnStatus: Int32 = "/bin/sh".withCString { shellPath in
                "-c".withCString { shellFlag in
                    command.withCString { commandText in
                        var arguments: [UnsafeMutablePointer<CChar>?] = [
                            UnsafeMutablePointer(mutating: shellPath),
                            UnsafeMutablePointer(mutating: shellFlag),
                            UnsafeMutablePointer(mutating: commandText),
                            nil
                        ]
                        return arguments.withUnsafeMutableBufferPointer { buffer in
                            posix_spawn(&childPID, shellPath, spawnActions, nil, buffer.baseAddress!, environ)
                        }
                    }
                }
            }

            posix_spawn_file_actions_destroy(spawnActions)
            close(pipeFDs[1])

            guard spawnStatus == 0 else {
                close(pipeFDs[0])
                completion("[TT] Shell 启动失败：\(String(cString: strerror(spawnStatus)))（错误码 \(spawnStatus)）。这可能是当前 iOS 环境的执行权限或系统路径限制。")
                return
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
            _ = waitpid(childPID, &waitStatus, 0)
            let outputText = String(decoding: output, as: UTF8.self)
                .trimmingCharacters(in: .newlines)
            let exitCode = (waitStatus & 0x7f) == 0 ? ((waitStatus >> 8) & 0xff) : 128 + (waitStatus & 0x7f)
            let displayedOutput = outputText.isEmpty ? "(命令没有输出)" : outputText
            completion("\(displayedOutput)\n[TT] 退出码：\(exitCode)")
        }
    }
}
