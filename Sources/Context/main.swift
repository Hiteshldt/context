import Foundation

// `Context --mcp` is the MCP server AI agents launch, and `Context --call <tool> '<json>'` runs one tool from a shell
// (see AgentBridge). Otherwise this is the app.
switch CommandLine.arguments.dropFirst().first {
case "--mcp": AgentBridge.run()
case "--call": AgentBridge.call(Array(CommandLine.arguments.dropFirst(2)))
default: MainActor.assumeIsolated { ContextApp.main() }
}
