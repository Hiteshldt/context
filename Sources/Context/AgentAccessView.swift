import SwiftUI

/// Settings for AI agent access (MCP): on or off, how to connect an agent, and what agents have done.
struct AgentAccessView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.pageTint) var tint
    @ObservedObject private var access = AgentAccess.shared
    @State private var showKey = false
    @State private var copied: String?

    var claudeCommand: String { "claude mcp add --scope user context -- \"\(access.command)\" --mcp" }
    var jsonConfig: String {
        """
        {
          "mcpServers": {
            "context": { "command": "\(access.command)", "args": ["--mcp"] }
          }
        }
        """
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 34, height: 34).background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text("AI agents").font(T.h2).foregroundStyle(Theme.ink)
                    Text("Let Claude Code and other AI tools on this Mac work on your maps").font(T.caption).foregroundStyle(Theme.ink2)
                }
                Spacer()
            }
            .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    toggleCard
                    if access.settings.enabled {
                        Label("Easiest: open a project, click ✨ AI at the top, and copy a ready-made prompt into any agent. It works even without the setup below.",
                              systemImage: "sparkles")
                            .font(T.small).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                        setup
                        activity
                    }
                    safety
                }
                .padding(.horizontal, 22).padding(.bottom, 20)
            }

            Rectangle().fill(Theme.border).frame(height: 1)
            HStack {
                if access.settings.enabled {
                    Button("New Access Key") { access.resetKey(); showKey = false }.buttonStyle(.plain).font(T.small).foregroundStyle(Theme.ink2)
                        .help("Agents connected over HTTP will need the new key. Agents using the command above pick it up by themselves.")
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(width: 640, height: 640)
        .background(Theme.background)
    }

    var toggleCard: some View {
        Card(padding: 16) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Allow AI agents to read and edit Context").font(T.h3).foregroundStyle(Theme.ink)
                    Text("Agents can list your projects, create and edit maps, add boxes and links, connect and group them, and add reminders to boxes. Changes show up live, and you can undo them with ⌘Z.")
                        .font(T.small).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 7, height: 7)
                        Text(status).font(T.caption).foregroundStyle(Theme.ink2)
                    }.padding(.top, 2)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { access.settings.enabled }, set: { access.setEnabled($0) })).toggleStyle(.switch).labelsHidden()
            }
        }
    }

    var status: String {
        if !access.settings.enabled { return "Off" }
        if let problem = access.problem { return problem }
        return access.running ? "On · listening on 127.0.0.1:\(access.settings.port), this Mac only" : "Starting…"
    }
    var statusColor: Color { !access.settings.enabled ? Theme.ink3 : (access.problem != nil ? Theme.overdue : (access.running ? Theme.success : Theme.today)) }

    var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(text: "Connect Claude Code")
                Text("Run this once in Terminal. Then ask Claude things like “map out how this repo is deployed”.")
                    .font(T.small).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                code(claudeCommand, id: "claude")
            }
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(text: "Other apps (Cursor, Windsurf, Claude Desktop, …)")
                Text("Add this to the app's MCP settings (for Cursor, ~/.cursor/mcp.json):").font(T.small).foregroundStyle(Theme.ink2)
                code(jsonConfig, id: "json")
            }
            VStack(alignment: .leading, spacing: 6) {
                Eyebrow(text: "Or connect over HTTP")
                Text("For tools that take a URL. Send the key as an Authorization: Bearer header.").font(T.small).foregroundStyle(Theme.ink2)
                code(access.endpoint, id: "url")
                HStack(spacing: 8) {
                    Text(showKey ? access.settings.token : String(repeating: "•", count: 24)).font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.ink2).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(showKey ? "Hide" : "Show Key") { showKey.toggle() }.buttonStyle(.softCompact)
                    copyButton(access.settings.token, id: "key", title: "Copy Key")
                }
                .padding(10).background(Theme.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.border))
            }
        }
    }

    func code(_ text: String, id: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(text).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.ink).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            copyButton(text, id: id, title: "Copy")
        }
        .padding(10).background(Theme.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.border))
    }

    func copyButton(_ text: String, id: String, title: String) -> some View {
        Button(copied == id ? "Copied" : title) {
            copyToClipboard(text)
            copied = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == id { copied = nil } }
        }.buttonStyle(.softCompact)
    }

    @ViewBuilder var activity: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: "What agents did")
            if access.activity.isEmpty {
                Text("Nothing yet. Changes agents make appear here.").font(T.small).foregroundStyle(Theme.ink3)
            } else {
                Card(padding: 8) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(access.activity.prefix(12)) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: item.failed ? "exclamationmark.circle" : "checkmark.circle").font(.system(size: 11))
                                    .foregroundStyle(item.failed ? Theme.overdue : Theme.success)
                                Text("\(item.client): \(item.summary)").font(T.small).foregroundStyle(Theme.ink).lineLimit(2)
                                Spacer(minLength: 6)
                                Text(item.date.formatted(date: .omitted, time: .shortened)).font(T.caption).foregroundStyle(Theme.ink3)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 5)
                        }
                    }
                }
            }
        }
    }

    var safety: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Only programs on this Mac can connect, with a private key. Web pages are refused.", systemImage: "lock")
            Label("Agents never see saved passwords.", systemImage: "key")
            Label("Nothing works while Context is locked, or when this is off.", systemImage: "hand.raised")
        }
        .font(T.caption).foregroundStyle(Theme.ink2)
    }
}

/// From a project's ✨ AI button: turn AI access on, then copy a ready-made prompt for any agent.
struct AIPromptPanel: View {
    @EnvironmentObject var store: Store
    @Environment(\.pageTint) var tint
    @ObservedObject private var access = AgentAccess.shared
    let project: Project
    let openSettings: () -> Void
    @State private var task: AgentPrompt.Task = .mapCode
    @State private var custom = ""
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 14, weight: .semibold)).foregroundStyle(tint)
                Text("Work on \(project.name) with AI").font(T.h3).foregroundStyle(Theme.ink).lineLimit(1)
            }
            if access.settings.enabled { prompts } else { turnOn }
        }
        .padding(16).frame(width: 380)
    }

    var turnOn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Let AI agents on this Mac, like Claude Code, Codex, or Cursor, read and edit this project's map. You'll get a prompt to paste into them.")
                .font(T.small).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            Button { access.setEnabled(true) } label: { Label("Turn On AI Access", systemImage: "sparkles").frame(maxWidth: .infinity) }
                .buttonStyle(.primary)
            Text("Only programs on this Mac can connect, and agents never see saved passwords. Turn it off any time in ⚙ → AI Agents.")
                .font(T.caption).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
        }
    }

    var prompts: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pick a task, copy the prompt, and paste it into Claude Code, Codex, Cursor, or any AI agent that can run commands on this Mac.")
                .font(T.small).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 2) {
                ForEach(AgentPrompt.Task.allCases) { option in
                    Button { task = option; copied = false } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: option.icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(task == option ? tint : Theme.ink3)
                                .frame(width: 18).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(option.title).font(T.small.weight(.medium)).foregroundStyle(Theme.ink)
                                Text(option.detail).font(T.caption).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: task == option ? "checkmark.circle.fill" : "circle").font(.system(size: 14))
                                .foregroundStyle(task == option ? tint : Theme.ink3.opacity(0.6))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 7)
                        .background(task == option ? tint.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            if task == .custom {
                TextField("What should the AI do with this project?", text: $custom, axis: .vertical)
                    .textFieldStyle(.plain).font(T.small).lineLimit(2...5)
                    .padding(8).background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            }
            Button {
                copyToClipboard(AgentPrompt.make(task, custom: custom, project: project, in: store.workspace, executable: access.command))
                copied = true
            } label: {
                Label(copied ? "Copied. Now paste it into your AI agent" : "Copy Prompt", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.primary)
            .disabled(task == .custom && custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            HStack(spacing: 6) {
                Circle().fill(Theme.success).frame(width: 6, height: 6)
                Text("AI access is on").font(T.caption).foregroundStyle(Theme.ink2)
                Spacer()
                Button("Setup & activity…", action: openSettings).buttonStyle(.plain).font(T.caption).foregroundStyle(tint)
            }
        }
    }
}
