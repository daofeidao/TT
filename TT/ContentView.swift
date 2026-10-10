import SwiftUI

struct ContentView: View {
    @State private var command = ""
    @State private var transcript = """
    TT Terminal
    Build milestone 1
    This is a UI/input test, not a real shell.
    """

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text("TT")
                    .font(.headline.monospaced())
                Spacer()
                Text("iOS 15+")
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
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

                TextField("输入测试文字或命令", text: $command)
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
    }

    private func submitCommand() {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        transcript += "\n\n$ \(text)\n[TT] Input received: \(text)"
        command = ""
    }
}
