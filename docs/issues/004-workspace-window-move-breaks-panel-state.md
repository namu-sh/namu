# Moving a workspace between windows loses backing panel state

- Severity: High
- Area: `NamuUI/App`, multi-window architecture
- Validation: Revalidated against current code on 2026-03-29
- Bucket: Resolved
- Status: Resolved 2026-03-29

## Summary

Moving a workspace to another window previously transferred only the `Workspace` value between `WorkspaceManager` instances. The backing `PanelManager` state and Bonsplit engine remained with the source window.

## Evidence (original)

- `NamuUI/App/AppDelegate.swift:365` creates each window with its own isolated `WorkspaceManager` and `PanelManager` pair.
- `NamuUI/App/AppDelegate.swift:409` deleted the source workspace from the source manager.
- `NamuUI/App/AppDelegate.swift:414` assigned the moved `Workspace` into the new window's `WorkspaceManager` only.
- `NamuUI/App/AppDelegate.swift:428` appended the moved `Workspace` into an existing target window's `WorkspaceManager` only.

## Impact (original)

- The moved workspace could appear in the target window without matching live panels.
- The source window could retain orphaned panel or layout-engine state.
- Multi-window behavior became unreliable and hard to recover from after drag-out or move actions.

## Resolution

`NamuKit/Services/PanelManager.swift` gained a `migrateWorkspace(id:to:)` method (line 405) that atomically transfers:

1. The Bonsplit layout engine for the workspace (`engines` dictionary entry).
2. All panels belonging to that workspace (`panels` dictionary entries).
3. Panel title observations — source observer registrations are removed and re-registered in the target `PanelManager`.

Both move paths in `NamuUI/App/AppDelegate.swift` now call this method before updating the `WorkspaceManager`:

- `moveWorkspaceToNewWindow` (line 432): calls `sourcePm.migrateWorkspace(id:to:)` after creating the new window context.
- `moveWorkspaceToWindow` (line 449): calls `sourcePm.migrateWorkspace(id:to:)` before appending the workspace to the target manager.

The source window is left with no orphaned engine or panel entries. The target window receives a fully intact layout engine and panel set, so the moved workspace renders with live panels immediately.

## Acceptance criteria (verified)

- After moving, the target window renders the workspace with live panels intact. ✓
- The source window no longer retains orphaned panel or engine state. ✓
- Both `moveWorkspaceToNewWindow` and `moveWorkspaceToWindow` migrate panel state atomically. ✓
