import SwiftUI

/// Sheet for adding or editing an MCP server configuration
struct MCPServerEditSheet: View {
    let server: MCPServerManager.MCPServerConfig?
    let onSave: (MCPServerManager.MCPServerConfig) -> Void
    let onCancel: () -> Void

    @State private var name: String = ""
    @State private var command: String = ""
    @State private var argsText: String = ""  // One arg per line
    @State private var envPairs: [(key: String, value: String)] = []
    @State private var enabled: Bool = true
    @State private var errorMessage: String?

    private var isEditing: Bool { server != nil }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(isEditing ? "Edit MCP Server" : "Add MCP Server")
                    .scaledFont(size: 16, weight: .semibold)
                    .foregroundColor(FazmColors.textPrimary)
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(size: 18)
                        .foregroundColor(FazmColors.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Divider()

            // Form
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Name
                    fieldSection("Name", hint: "Unique identifier (e.g. \"my-database\")") {
                        TextField("server-name", text: $name)
                            .textFieldStyle(.roundedBorder)
                            .disabled(isEditing)
                    }

                    // Command
                    fieldSection("Command", hint: "Path to the MCP server executable") {
                        TextField("/usr/local/bin/my-mcp-server", text: $command)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Args
                    fieldSection("Arguments", hint: "One per line (optional)") {
                        TextEditor(text: $argsText)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(minHeight: 50, maxHeight: 80)
                            .padding(4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(FazmColors.textTertiary.opacity(0.3), lineWidth: 1)
                            )
                    }

                    // Environment Variables
                    fieldSection("Environment Variables", hint: "Optional key=value pairs") {
                        VStack(spacing: 8) {
                            ForEach(envPairs.indices, id: \.self) { idx in
                                HStack(spacing: 8) {
                                    TextField("KEY", text: Binding(
                                        get: { envPairs[idx].key },
                                        set: { envPairs[idx].key = $0 }
                                    ))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 120)

                                    Text("=")
                                        .foregroundColor(FazmColors.textTertiary)

                                    TextField("value", text: Binding(
                                        get: { envPairs[idx].value },
                                        set: { envPairs[idx].value = $0 }
                                    ))
                                    .textFieldStyle(.roundedBorder)

                                    Button(action: { envPairs.remove(at: idx) }) {
                                        Image(systemName: "minus.circle")
                                            .foregroundColor(.red.opacity(0.7))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            Button(action: { envPairs.append((key: "", value: "")) }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "plus")
                                    Text("Add Variable")
                                }
                                .scaledFont(size: 12, weight: .medium)
                                .foregroundColor(FazmColors.purplePrimary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Enabled toggle
                    Toggle("Enabled", isOn: $enabled)
                        .toggleStyle(.switch)

                    if let errorMessage {
                        Text(errorMessage)
                            .scaledFont(size: 12)
                            .foregroundColor(.red)
                    }
                }
                .padding(20)
            }

            Divider()

            // Footer buttons
            HStack {
                Spacer()

                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)

                Button(action: saveServer) {
                    Text(isEditing ? "Save" : "Add Server")
                        .scaledFont(size: 13, weight: .medium)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(FazmColors.purplePrimary)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(20)
        }
        .frame(width: 480, minHeight: 400)
        .background(FazmColors.backgroundPrimary)
        .onAppear {
            if let server {
                name = server.name
                command = server.command
                argsText = server.args.joined(separator: "\n")
                envPairs = server.env.map { (key: $0.key, value: $0.value) }
                    .sorted(by: { $0.key < $1.key })
                enabled = server.enabled
            }
        }
    }

    private func fieldSection<Content: View>(_ title: String, hint: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .scaledFont(size: 13, weight: .medium)
                .foregroundColor(FazmColors.textPrimary)
            Text(hint)
                .scaledFont(size: 11)
                .foregroundColor(FazmColors.textTertiary)
            content()
        }
    }

    private func saveServer() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else {
            errorMessage = "Name is required"
            return
        }
        guard !trimmedCommand.isEmpty else {
            errorMessage = "Command is required"
            return
        }

        // Check for duplicate name when adding
        if !isEditing && MCPServerManager.shared.servers.contains(where: { $0.name == trimmedName }) {
            errorMessage = "A server with this name already exists"
            return
        }

        let args = argsText
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var env: [String: String] = [:]
        for pair in envPairs where !pair.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            env[pair.key.trimmingCharacters(in: .whitespacesAndNewlines)] = pair.value
        }

        let config = MCPServerManager.MCPServerConfig(
            name: trimmedName,
            command: trimmedCommand,
            args: args,
            env: env,
            enabled: enabled
        )
        onSave(config)
    }
}
