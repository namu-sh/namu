import Foundation

// MARK: - CLI Command Protocol

/// Protocol for standalone CLI commands that replace switch-case entries in handleTmuxCompat.
/// Each conforming type handles one tmux-compat command (e.g., split-window, select-pane).
protocol CLICommand {
    /// Primary command name (e.g., "split-window")
    static var name: String { get }
    /// Aliases (e.g., ["splitw"])
    static var aliases: [String] { get }
    /// One-line help text
    static var help: String { get }

    init(client: SocketClient, args: [String]) throws
    func run() throws
}

// MARK: - CLI Command Registry

struct CLICommandRegistry {
    private var commands: [String: CLICommand.Type] = [:]

    mutating func register(_ command: CLICommand.Type) {
        commands[command.name] = command
        for alias in command.aliases {
            commands[alias] = command
        }
    }

    func resolve(_ name: String) -> CLICommand.Type? {
        commands[name]
    }

    var allCommands: [CLICommand.Type] {
        var seen = Set<String>()
        var result: [CLICommand.Type] = []
        for (_, type) in commands.sorted(by: { $0.key < $1.key }) {
            let typeName = type.name
            if seen.insert(typeName).inserted {
                result.append(type)
            }
        }
        return result
    }
}

// MARK: - Global Registry

/// The shared registry used by handleTmuxCompat dispatch.
/// Only commands with dedicated CLICommand implementations are registered here.
/// The remaining 33+ tmux-compat commands are handled in handleTmuxCompat's switch statement.
var tmuxCommandRegistry: CLICommandRegistry = {
    var registry = CLICommandRegistry()
    registry.register(SplitWindowCommand.self)
    registry.register(SelectPaneCommand.self)
    registry.register(ListPanesCommand.self)
    registry.register(CapturePaneCommand.self)
    return registry
}()
