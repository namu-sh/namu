# Session persistence silently flattens real split layouts

- Severity: Medium
- Area: `NamuKit/Services`
- Validation: Revalidated against current code on 2026-03-29
- Bucket: **Resolved**

## Summary

Session persistence serializes `Workspace.paneTree`, but the mirrored tree was rebuilt from Bonsplit as a flat chain of horizontal splits rather than the true layout tree. Restore could therefore preserve pane count while losing actual structure.

## Resolution

`PanelManager.syncWorkspaceFromEngine()` now walks `BonsplitController.treeSnapshot()` (`ExternalTreeNode`) to rebuild `PaneTree` with correct structure:

- Split orientation (horizontal/vertical) is preserved from `ExternalSplitNode.orientation`
- Split ratios are preserved from `ExternalSplitNode.dividerPosition`
- Nesting depth is preserved by recursive tree walk
- Tab-to-panel mappings are resolved via `BonsplitLayoutEngine.panelID(for:)`

The flat chain rebuild (`insertSplit` with all horizontal) has been replaced by `paneTreeFromExternalNode()` which produces a structurally faithful mirror.

## Acceptance criteria (met)

- A nested mixed-orientation layout round-trips through save and restore without structural drift.
- Split ratios are restored from the authoritative Bonsplit source.
- Persisted layout data comes from a single authoritative source (BonsplitController via treeSnapshot).
