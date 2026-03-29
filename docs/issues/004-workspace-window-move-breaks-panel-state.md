# Moving a workspace between windows loses backing panel state

- Severity: High
- Area: `NamuUI/App`, multi-window architecture
- Validation: Revalidated against current code on 2026-03-29
- Bucket: Needs architectural correction

## Summary

Moving a workspace to another window currently transfers only the `Workspace` value between `WorkspaceManager` instances. The backing `PanelManager` state and Bonsplit engine remain with the source window.

## Evidence

- `NamuUI/App/AppDelegate.swift:365` creates each window with its own isolated `WorkspaceManager` and `PanelManager` pair.
- `NamuUI/App/AppDelegate.swift:409` deletes the source workspace from the source manager.
- `NamuUI/App/AppDelegate.swift:414` assigns the moved `Workspace` into the new window's `WorkspaceManager` only.
- `NamuUI/App/AppDelegate.swift:428` appends the moved `Workspace` into an existing target window's `WorkspaceManager` only.

## Impact

- The moved workspace can appear in the target window without matching live panels.
- The source window may retain orphaned panel or layout-engine state.
- Multi-window behavior becomes unreliable and hard to recover from after drag-out or move actions.

## Suggested fix

- Move workspace ownership through a higher-level abstraction that migrates both workspace metadata and backing panel/layout state.
- Alternatively serialize the workspace to a portable snapshot and rehydrate it into the target `PanelManager`, then tear down the source cleanly.
- Add dedicated multi-window move tests.

## Acceptance criteria

- After moving, the target window renders the workspace with live panels intact.
- The source window no longer retains orphaned panel or engine state.
- Repeated moves between windows preserve focus, layout, and terminal sessions as designed.
