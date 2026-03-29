# Workspace lifecycle bypasses panel bootstrapping and cleanup

- Severity: High
- Area: `NamuUI`, `NamuKit/IPC`, `NamuKit/Config`, `NamuKit/Services`
- Validation: Revalidated against current code on 2026-03-29
- Bucket: **Resolved**

## Summary

Several remaining workspace create and delete paths still mutate `WorkspaceManager` directly without invoking `PanelManager` lifecycle hooks. The codebase now has a clearer intended creation entry point, but IPC, config, and delete paths still bypass it.

## Resolution

- `PanelManager.createWorkspace()` is the single entry point for workspace creation (bootstraps engine + terminal, auto-selects).
- `PanelManager.deleteWorkspace()` is the single entry point for workspace deletion (cleans up engine + panels, then removes from WorkspaceManager).
- All callers now route through PanelManager:
  - `SidebarViewModel.createWorkspace()` → `panelManager.createWorkspace()`
  - `SidebarViewModel.closeWorkspace()` → `panelManager.deleteWorkspace()`
  - `AppDelegate` Cmd+T → `panelManager.createWorkspace()`
  - `AppDelegate` menu → `panelManager.createWorkspace()`
  - `CommandPaletteView` → `panelManager.createWorkspace()`
  - `WorkspaceCommands` IPC create/delete/close → `panelManager.createWorkspace()` / `panelManager.deleteWorkspace()`
  - `CommandExecutor` config create/delete → `panelManager.createWorkspace()` / `panelManager.deleteWorkspace()`
  - `ServiceContainer` shell exit → `panelManager.deleteWorkspace()`
- Tests verify the structural constraint: direct `wm.createWorkspace()` does NOT bootstrap an engine.

## Remaining edge case

- `AppDelegate.moveWorkspaceToNewWindow()` / `moveWorkspaceToWindow()` still transfer workspace values between WorkspaceManager instances without migrating the backing engine/panels. This is tracked in issue 004.
