# Namu Terminal Skill

This skill gives Claude Code direct access to terminal panes in Namu via the IPC socket.

## Available Commands

Use `namu` CLI or JSON-RPC via the socket at `$NAMU_SOCKET`.

### Pane Management

```bash
# List all panes in the active workspace
namu pane list

# Split the focused pane horizontally
namu pane split --direction horizontal

# Split the focused pane vertically
namu pane split --direction vertical

# Send keys to the focused pane
namu pane send_keys "ls -la\n"

# Send keys to a specific pane
namu pane send_keys --pane_id <uuid> "git status\n"

# Read the visible screen content
namu pane read_screen

# Read more lines (scrollback)
namu pane read_screen --lines 100

# Close a pane
namu pane close --pane_id <uuid>

# Swap two panes
namu pane swap --pane_id <uuid-a> --target_pane_id <uuid-b>

# Zoom a pane (fullscreen)
namu pane zoom --pane_id <uuid>

# Unzoom
namu pane unzoom

# Break a pane out into a new workspace
namu pane break --pane_id <uuid>
```

### Workspace Management

```bash
# List workspaces
namu workspace list

# Create a workspace
namu workspace create --title "My Workspace"

# Switch to a workspace
namu workspace select --id <uuid>

# Rename a workspace
namu workspace rename --id <uuid> --title "New Name"

# Pin a workspace
namu workspace pin --id <uuid>

# Set workspace color
namu workspace color --id <uuid> --color "#FF6B6B"
```

## Tips

- Use `--json` flag for machine-readable output: `namu pane read_screen --json`
- Set `NAMU_SOCKET` env var to target a specific Namu instance
- Commands return JSON-RPC responses; check `result` field for data
