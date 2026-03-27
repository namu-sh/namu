# Namu Debug Skill

This skill exposes Namu's internal debug and diagnostic commands.

## Available Commands

```bash
# Check if Namu is running
namu system ping

# Get Namu version
namu system version

# Get overall status (version, PID, socket path)
namu system status

# List all available IPC commands
namu system capabilities
```

## Debug Stats (debug builds only)

In debug builds, the trace log is written to `/tmp/namu-trace.log`:

```bash
# Tail the trace log
tail -f /tmp/namu-trace.log

# Check memory usage (debug builds)
namu debug stats
```

## Notifications

```bash
# Send a notification
namu notification create --title "Build Done" --body "Tests passed"

# Send with sound
namu notification create --title "Alert" --body "Attention needed" --sound true
```
