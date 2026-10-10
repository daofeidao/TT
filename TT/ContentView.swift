import SwiftUI

struct ContentView: View {
    @State private var command = ""
    @State private var transcript = """
    TT 终端 · 第二版
    当前为输入回显测试，尚未连接真实命令执行环境。
    输入内容后点击发送，即可在窗口中查看回显。
    """
    @State private var history: [String] = []
    @State private var showHistory = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)

                Text("TT 终端")
                    .font(.headline.monospaced())

                Text("第二版")
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
                    Text(transcript)
                        .font(.system(size: 14, weight: .regular, design: .monospaced))
                        .foregroundColor(Color(red: 0.76, green: 0.96, blue: 0.78))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(14)
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

                TextField("输入文字或命令（目前仅回显）", text: $command)
                    .font(.system(size: 15, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .submitLabel(.send)
                    .onSubmit(submitCommand)
                    .accessibilityIdentifier("tt.command.input")

                Button(action: submitCommand) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 25))
                }
                .accessibilityLabel("发送输入")
                .accessibilityIdentifier("tt.command.send")
                .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
        guard !text.isEmpty else { return }

        transcript += "\n\n› \(text)\n[TT] 已收到输入：\(text)"
        history.append(text)
        if history.count > 50 {
            history.removeFirst(history.count - 50)
        }
        command = ""
    }

    private func clearTranscript() {
        transcript = "TT 终端已清空。\n提示：当前版本只测试输入与回显，不会真正执行命令。"
    }
}
