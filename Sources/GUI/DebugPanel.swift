// ============================================================================
// DebugPanel.swift — Request/response JSON viewer with copy buttons
// ============================================================================

import SwiftUI
import AppKit

struct DebugPanel: View {
    @Bindable var viewModel: ChatViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "ant.circle.fill")
                    .foregroundStyle(.orange)
                Text("Debug Inspector")
                    .font(.headline)
                Spacer()
                if viewModel.selectedMessage != nil {
                    Button("Clear") {
                        viewModel.selectedMessageId = nil
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            if let msg = viewModel.selectedMessage {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Message info
                        infoCard {
                            HStack {
                                Label(msg.role == "user" ? "User Message" : "AI Response",
                                      systemImage: msg.role == "user" ? "person.circle" : "cpu")
                                Spacer()
                                if let ms = msg.durationMs {
                                    Text("\(ms)ms")
                                        .font(.system(.caption, design: .monospaced))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.green.opacity(0.1))
                                        .clipShape(Capsule())
                                }
                                if let tokens = msg.tokenCount {
                                    Text("~\(tokens) tokens")
                                        .font(.system(.caption, design: .monospaced))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.blue.opacity(0.1))
                                        .clipShape(Capsule())
                                }
                            }
                            .font(.caption)
                        }

                        // curl command
                        if let curl = msg.curlCommand {
                            codeSection(
                                title: "curl Command (copy & paste to reproduce)",
                                icon: "terminal",
                                text: curl,
                                color: .purple
                            )
                        }

                        // Content
                        codeSection(
                            title: "Content",
                            icon: "text.quote",
                            text: msg.content,
                            color: .primary
                        )

                        // Request JSON
                        if let json = msg.requestJSON {
                            codeSection(
                                title: "HTTP Request Body",
                                icon: "arrow.up.doc.fill",
                                text: json,
                                color: .orange
                            )
                        }

                        // Response JSON
                        if let json = msg.responseJSON {
                            codeSection(
                                title: "HTTP Response Body",
                                icon: "arrow.down.doc.fill",
                                text: json,
                                color: .green
                            )
                        }
                    }
                    .padding(12)
                }
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "ant.circle")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No message selected")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                    Text("Click the \(Image(systemName: "ant.circle")) Inspect button\nnext to any message")
                        .font(.caption)
                        .foregroundStyle(.quaternary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Components

    @ViewBuilder
    private func infoCard(@ViewBuilder content: () -> some View) -> some View {
        content()
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func codeSection(title: String, icon: String, text: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(title)
                    .fontWeight(.medium)
                Spacer()
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .onHover { h in if h { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
            }
            .font(.caption)

            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(color.opacity(0.15), lineWidth: 1)
                )
        }
    }
}
