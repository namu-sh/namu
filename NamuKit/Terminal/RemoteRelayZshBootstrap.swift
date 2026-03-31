import Foundation

/// Generates zsh shim scripts for remote relay sessions.
///
/// When Namu connects to a remote machine via SSH, it needs to inject shell integration
/// without modifying the user's dotfiles. This is done by creating a temporary directory
/// containing shim scripts for each zsh startup file (.zshenv, .zprofile, .zshrc, .zlogin).
/// Each shim sources the real file from the user's ZDOTDIR (or $HOME) and then injects
/// the Namu shell integration source line.
///
/// Usage:
///   let script = RemoteRelayZshBootstrap.generateBootstrapScript(realZDOTDIR: nil)
///   // Write `script` to a temp dir on the remote, then launch zsh with ZDOTDIR set.
public enum RemoteRelayZshBootstrap {

    /// Generate a shell script that, when executed on the remote, writes shim zsh startup
    /// files into a temporary directory and prints the path of that directory.
    ///
    /// The caller should:
    ///   1. Run this script on the remote machine (e.g. via SSH).
    ///   2. Capture the printed temp directory path.
    ///   3. Launch zsh with `ZDOTDIR=<temp-dir>`.
    ///
    /// - Parameter realZDOTDIR: The user's real ZDOTDIR on the remote, or nil to use $HOME.
    /// - Returns: A POSIX shell script string.
    public static func generateBootstrapScript(realZDOTDIR: String?) -> String {
        let zdotdirExpr = realZDOTDIR.map { "\"\($0)\"" } ?? "$HOME"

        // Each shim file content as an array of lines.
        let zshenvLines = zshEnvLines(zdotdirExpr: zdotdirExpr)
        let zshprofileLines = zshProfileLines(zdotdirExpr: zdotdirExpr)
        let zshrcLines = zshRCLines(zdotdirExpr: zdotdirExpr)
        let zshloginLines = zshLoginLines(zdotdirExpr: zdotdirExpr)

        func writeFile(_ name: String, lines: [String]) -> String {
            let body = lines.map { "  echo \(shellQuote($0)) >> \"$NAMU_ZDOTDIR/\(name)\"" }.joined(separator: "\n")
            return body
        }

        return """
        #!/bin/sh
        # Namu remote relay zsh bootstrap — generated, do not edit
        NAMU_ZDOTDIR=$(mktemp -d)
        export NAMU_REAL_ZDOTDIR=\(zdotdirExpr)

        # .zshenv
        \(writeFile(".zshenv", lines: zshenvLines))

        # .zprofile
        \(writeFile(".zprofile", lines: zshprofileLines))

        # .zshrc
        \(writeFile(".zshrc", lines: zshrcLines))

        # .zlogin
        \(writeFile(".zlogin", lines: zshloginLines))

        chmod 600 "$NAMU_ZDOTDIR"/.z*
        echo "$NAMU_ZDOTDIR"
        """
    }

    // MARK: - Shim file line generators

    /// Lines for .zshenv — runs first for every zsh invocation (interactive and non-interactive).
    /// This is the right place to set ZDOTDIR so subsequent files load from our shim dir.
    private static func zshEnvLines(zdotdirExpr: String) -> [String] {
        [
            // If the user has their own ZDOTDIR set, capture it so other shims can source it.
            "if [ -n \"${ZDOTDIR:-}\" ] && [ \"$ZDOTDIR\" != \"$NAMU_ZDOTDIR\" ]; then",
            "  export NAMU_REAL_ZDOTDIR=\"$ZDOTDIR\"",
            "fi",
            // Source the real .zshenv if present.
            "[ -f \"$NAMU_REAL_ZDOTDIR/.zshenv\" ] && source \"$NAMU_REAL_ZDOTDIR/.zshenv\"",
        ] + histfileLines() + [
            // Re-assert our shim ZDOTDIR so zsh keeps loading our shims.
            "export ZDOTDIR=\"$NAMU_ZDOTDIR\"",
        ]
    }

    /// Lines for .zprofile — runs for login shells after .zshenv.
    private static func zshProfileLines(zdotdirExpr: String) -> [String] {
        [
            "[ -f \"$NAMU_REAL_ZDOTDIR/.zprofile\" ] && source \"$NAMU_REAL_ZDOTDIR/.zprofile\"",
        ]
    }

    /// Lines for .zshrc — runs for interactive shells.
    private static func zshRCLines(zdotdirExpr: String) -> [String] {
        histfileLines() + [
            "[ -f \"$NAMU_REAL_ZDOTDIR/.zshrc\" ] && source \"$NAMU_REAL_ZDOTDIR/.zshrc\"",
            // Inject Namu shell integration.
            namuShellIntegrationLine(),
        ]
    }

    /// Lines for .zlogin — runs for login shells after .zshrc.
    private static func zshLoginLines(zdotdirExpr: String) -> [String] {
        [
            "[ -f \"$NAMU_REAL_ZDOTDIR/.zlogin\" ] && source \"$NAMU_REAL_ZDOTDIR/.zlogin\"",
        ]
    }

    // MARK: - Shared helpers

    /// Lines that ensure HISTFILE points to the user's real history file, not the shim dir.
    private static func histfileLines() -> [String] {
        [
            "if [ -z \"${HISTFILE:-}\" ] || [ \"$HISTFILE\" = \"$NAMU_ZDOTDIR/.zsh_history\" ]; then",
            "  export HISTFILE=\"$NAMU_REAL_ZDOTDIR/.zsh_history\"",
            "fi",
        ]
    }

    /// Shell line that sources the Namu shell integration script.
    private static func namuShellIntegrationLine() -> String {
        // The path is injected via NAMU_SHELL_INTEGRATION env var set by the relay process.
        "[ -n \"${NAMU_SHELL_INTEGRATION:-}\" ] && source \"$NAMU_SHELL_INTEGRATION\""
    }

    /// Single-quote a shell string, escaping any embedded single quotes.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
