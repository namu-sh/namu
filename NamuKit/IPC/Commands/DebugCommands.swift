import Foundation
import Bonsplit
#if canImport(AppKit)
import AppKit
#endif

/// Handlers for the debug.* command namespace.
/// Diagnostics, layout introspection, screenshots, panel snapshots, render stats, flash counters, and focus override.
@MainActor
final class DebugCommands {

    private let workspaceManager: WorkspaceManager
    private let panelManager: PanelManager

    /// Stored panel snapshots for pixel-diff comparison.
    /// Access is safe without locks — this class is @MainActor isolated.
    private var panelSnapshots: [UUID: PanelSnapshotState] = [:]

    init(workspaceManager: WorkspaceManager, panelManager: PanelManager) {
        self.workspaceManager = workspaceManager
        self.panelManager = panelManager
    }

    // MARK: - Registration

    func register(in registry: CommandRegistry) {
        // Layout & introspection
        registry.register(HandlerRegistration(
            method: "debug.layout",
            execution: .mainActor,
            safety: .safe,
            handler: { [weak self] req in try await self?.layout(req) ?? .notAvailable(req) }
        ))

        // Screenshots
        registry.register(HandlerRegistration(
            method: "debug.window.screenshot",
            execution: .mainActor,
            safety: .safe,
            handler: { [weak self] req in try await self?.windowScreenshot(req) ?? .notAvailable(req) }
        ))

        // Panel snapshots
        registry.register(HandlerRegistration(
            method: "debug.panel_snapshot",
            execution: .mainActor,
            safety: .safe,
            handler: { [weak self] req in try await self?.panelSnapshot(req) ?? .notAvailable(req) }
        ))
        registry.register(HandlerRegistration(
            method: "debug.panel_snapshot.reset",
            execution: .mainActor,
            safety: .safe,
            handler: { [weak self] req in try await self?.panelSnapshotReset(req) ?? .notAvailable(req) }
        ))

        // Flash counters
        registry.register(HandlerRegistration(
            method: "debug.flash.count",
            execution: .mainActor,
            safety: .safe,
            handler: { [weak self] req in try await self?.flashCount(req) ?? .notAvailable(req) }
        ))
        registry.register(HandlerRegistration(
            method: "debug.flash.reset",
            execution: .mainActor,
            safety: .safe,
            handler: { [weak self] req in try await self?.flashReset(req) ?? .notAvailable(req) }
        ))

        // Enhanced render stats
        registry.register(HandlerRegistration(
            method: "debug.render_stats",
            execution: .mainActor,
            safety: .safe,
            handler: { [weak self] req in try await self?.renderStats(req) ?? .notAvailable(req) }
        ))

        // App focus override
        registry.register(HandlerRegistration(
            method: "debug.app_focus.override",
            execution: .mainActor,
            safety: .normal,
            handler: { [weak self] req in try await self?.appFocusOverride(req) ?? .notAvailable(req) }
        ))
        registry.register(HandlerRegistration(
            method: "debug.app_focus.simulate_active",
            execution: .mainActor,
            safety: .normal,
            handler: { [weak self] req in try await self?.appFocusSimulateActive(req) ?? .notAvailable(req) }
        ))
    }

    // MARK: - debug.layout

    /// Returns the full layout tree for the active workspace as JSON, enriched with panel metadata.
    private func layout(_ req: JSONRPCRequest) throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        // Resolve workspace
        let wsID: UUID
        if let wsValue = params["workspace_id"], case .string(let idStr) = wsValue,
           let id = UUID(uuidString: idStr) {
            wsID = id
        } else {
            guard let selected = workspaceManager.selectedWorkspaceID else {
                throw JSONRPCError(code: -32001, message: "No active workspace")
            }
            wsID = selected
        }

        let engine = panelManager.engine(for: wsID)
        let tree = engine.treeSnapshot()
        let layoutSnap = engine.layoutSnapshot()

        // Serialize the tree with panel metadata
        let treeJSON = serializeTreeNode(tree, engine: engine)

        // Build pane geometry list
        let panesJSON: [JSONRPCValue] = layoutSnap.panes.map { pane in
            .object([
                "pane_id": .string(pane.paneId),
                "frame": pixelRectToValue(pane.frame),
                "selected_tab_id": pane.selectedTabId.map { .string($0) } ?? .null,
                "tab_ids": .array(pane.tabIds.map { .string($0) }),
            ])
        }

        // Window number metadata for correlating with CGWindowListCreateImage
        let mainWindowNumber = NSApp.mainWindow?.windowNumber ?? 0
        let keyWindowNumber = NSApp.keyWindow?.windowNumber ?? 0

        return .success(id: req.id, result: .object([
            "workspace_id": .string(wsID.uuidString),
            "tree": treeJSON,
            "container_frame": pixelRectToValue(layoutSnap.containerFrame),
            "focused_pane_id": layoutSnap.focusedPaneId.map { .string($0) } ?? .null,
            "panes": .array(panesJSON),
            "timestamp": .double(layoutSnap.timestamp),
            "main_window_number": .int(mainWindowNumber),
            "key_window_number": .int(keyWindowNumber),
        ]))
    }

    // MARK: - debug.window.screenshot

    private func windowScreenshot(_ req: JSONRPCRequest) throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        let label = params["label"].flatMap { if case .string(let s) = $0 { return s } else { return nil } }

        guard let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first else {
            throw JSONRPCError(code: -32001, message: "No window available")
        }

        let windowID = CGWindowID(window.windowNumber)
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.boundsIgnoreFraming, .nominalResolution]
        ) else {
            throw JSONRPCError.internalError("CGWindowListCreateImage failed")
        }

        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            throw JSONRPCError.internalError("PNG encoding failed")
        }

        // Write to temp directory
        let snapshotId = "\(ISO8601DateFormatter().string(from: Date()))_\(UUID().uuidString.prefix(8))"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("namu-screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let filename = label.map { "\($0)_\(snapshotId).png" } ?? "\(snapshotId).png"
        let outputPath = dir.appendingPathComponent(filename)
        try pngData.write(to: outputPath)

        return .success(id: req.id, result: .object([
            "snapshot_id": .string(snapshotId),
            "path": .string(outputPath.path),
            "width": .int(cgImage.width),
            "height": .int(cgImage.height),
        ]))
    }

    // MARK: - debug.panel_snapshot

    private func panelSnapshot(_ req: JSONRPCRequest) throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        let label = params["label"].flatMap { if case .string(let s) = $0 { return s } else { return nil } }

        // Resolve surface
        let panelID: UUID
        if let sidValue = params["surface_id"], case .string(let sidStr) = sidValue,
           let sid = UUID(uuidString: sidStr) {
            panelID = sid
        } else {
            guard let wsID = workspaceManager.selectedWorkspaceID,
                  let focused = panelManager.focusedPanelID(in: wsID) else {
                throw JSONRPCError(code: -32001, message: "No focused surface")
            }
            panelID = focused
        }

        guard let panel = panelManager.panel(for: panelID) else {
            throw JSONRPCError(code: -32001, message: "Terminal panel not found")
        }

        // Capture snapshot from the surface view
        let surfaceView = panel.surfaceView
        guard let cgImage = surfaceView.captureSnapshot() else {
            throw JSONRPCError.internalError("Failed to capture surface snapshot")
        }

        let width = cgImage.width
        let height = cgImage.height
        let bytesPerRow = width * 4
        let bufferSize = bytesPerRow * height

        // Create RGBA buffer
        var pixelData = Data(count: bufferSize)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        pixelData.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            if let ctx = CGContext(
                data: baseAddress,
                width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) {
                ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
        }

        let newSnapshot = PanelSnapshotState(width: width, height: height, bytesPerRow: bytesPerRow, rgba: pixelData)

        // Compare with previous snapshot
        let changedPixels: Int

        if let previous = panelSnapshots[panelID] {
            changedPixels = countChangedPixels(previous: previous, current: newSnapshot)
        } else {
            changedPixels = -1  // First snapshot, nothing to compare
        }
        panelSnapshots[panelID] = newSnapshot


        // Save PNG to temp
        let snapshotId = "\(UUID().uuidString.prefix(8))"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("namu-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            throw JSONRPCError.internalError("PNG encoding failed")
        }

        let filename = label.map { "\($0)_\(snapshotId).png" } ?? "\(snapshotId).png"
        let outputPath = dir.appendingPathComponent(filename)
        try pngData.write(to: outputPath)

        return .success(id: req.id, result: .object([
            "panel_id": .string(panelID.uuidString),
            "changed_pixels": .int(changedPixels),
            "width": .int(width),
            "height": .int(height),
            "path": .string(outputPath.path),
        ]))
    }

    // MARK: - debug.panel_snapshot.reset

    private func panelSnapshotReset(_ req: JSONRPCRequest) throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        // Per-panel reset if surface_id provided, otherwise clear all
        if let sidValue = params["surface_id"], case .string(let sidStr) = sidValue,
           let sid = UUID(uuidString: sidStr) {
            panelSnapshots.removeValue(forKey: sid)
            return .success(id: req.id, result: .object([
                "reset": .bool(true),
                "surface_id": .string(sidStr),
            ]))
        }

        panelSnapshots.removeAll()
        return .success(id: req.id, result: .object(["reset": .bool(true), "all": .bool(true)]))
    }

    // MARK: - debug.flash.count

    private func flashCount(_ req: JSONRPCRequest) throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        let panelID: UUID
        if let sidValue = params["surface_id"], case .string(let sidStr) = sidValue,
           let sid = UUID(uuidString: sidStr) {
            panelID = sid
        } else {
            guard let wsID = workspaceManager.selectedWorkspaceID,
                  let focused = panelManager.focusedPanelID(in: wsID) else {
                throw JSONRPCError(code: -32001, message: "No focused surface")
            }
            panelID = focused
        }

        guard let panel = panelManager.panel(for: panelID) else {
            throw JSONRPCError(code: -32001, message: "Terminal panel not found")
        }

        return .success(id: req.id, result: .object([
            "surface_id": .string(panelID.uuidString),
            "count": .int(panel.surfaceView.flashCount),
        ]))
    }

    // MARK: - debug.flash.reset

    private func flashReset(_ req: JSONRPCRequest) throws -> JSONRPCResponse {
        // Reset all terminal panels
        for wsID in workspaceManager.workspaces.map(\.id) {
            for pid in panelManager.allPanelIDs(in: wsID) {
                panelManager.panel(for: pid)?.surfaceView.resetFlashCount()
            }
        }
        return .success(id: req.id, result: .object(["reset": .bool(true)]))
    }

    // MARK: - debug.render_stats

    /// Enhanced render stats with 16 fields (vs the 3 in system.render_stats).
    private func renderStats(_ req: JSONRPCRequest) throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        // Optional surface targeting
        let targetPanel: TerminalPanel?
        if let sidValue = params["surface_id"], case .string(let sidStr) = sidValue,
           let sid = UUID(uuidString: sidStr) {
            targetPanel = panelManager.panel(for: sid)
        } else if let wsID = workspaceManager.selectedWorkspaceID,
                  let focused = panelManager.focusedPanelID(in: wsID) {
            targetPanel = panelManager.panel(for: focused)
        } else {
            targetPanel = nil
        }

        // Collect Metal layer stats
        let layers = NamuMetalLayer.all
        let layerStats: [JSONRPCValue] = layers.enumerated().map { index, layer in
            let stats = layer.extendedDebugStats()
            // layerContentsKey: hash of current IOSurface contents for stale-framebuffer detection
            let contentsKey: String
            if let contents = layer.contents {
                contentsKey = String(describing: type(of: contents)) + "@\(ObjectIdentifier(contents as AnyObject).hashValue)"
            } else {
                contentsKey = "nil"
            }
            return .object([
                "layer_index": .int(index),
                "draw_count": .int(stats.drawCount),
                "last_draw_time": .double(stats.lastDrawTime),
                "present_count": .int(stats.presentCount),
                "last_present_time": .double(stats.lastPresentTime),
                "layer_class": .string(stats.layerClass),
                "layer_contents_key": .string(contentsKey),
            ])
        }

        // Window & app state
        let keyWindow = NSApp.keyWindow
        var result: [String: JSONRPCValue] = [
            "surfaces": .array(layerStats),
            "app_is_active": .bool(NSApp.isActive),
            "window_is_key": .bool(keyWindow != nil),
            "window_occlusion_visible": .bool(
                keyWindow?.occlusionState.contains(.visible) ?? false
            ),
        ]

        // Panel-specific stats if available
        if let panel = targetPanel {
            let view = panel.surfaceView
            result["panel_id"] = .string(panel.id.uuidString)
            result["is_first_responder"] = .bool(view.window?.firstResponder === view)
            result["in_window"] = .bool(view.window != nil)
            result["flash_count"] = .int(view.flashCount)
            // Ghostty surface state
            let hasSurface = view.surface != nil
            result["has_surface"] = .bool(hasSurface)
            result["is_active"] = .bool(view.window?.isKeyWindow ?? false && view.window?.firstResponder === view)
        }

        return .success(id: req.id, result: .object(result))
    }

    // MARK: - debug.app_focus.override

    private func appFocusOverride(_ req: JSONRPCRequest) throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        if let stateValue = params["state"], case .string(let state) = stateValue {
            switch state {
            case "active":
                AppDelegate.focusOverride = true
            case "inactive":
                AppDelegate.focusOverride = false
            case "clear", "none":
                AppDelegate.focusOverride = nil
            default:
                throw JSONRPCError(code: -32602, message: "Invalid state: \(state). Use active|inactive|clear")
            }
        } else if let focusedValue = params["focused"] {
            switch focusedValue {
            case .bool(let b):
                AppDelegate.focusOverride = b
            case .null:
                AppDelegate.focusOverride = nil
            default:
                throw JSONRPCError(code: -32602, message: "focused must be bool or null")
            }
        } else {
            throw JSONRPCError(code: -32602, message: "Missing param: state or focused")
        }

        let overrideValue: JSONRPCValue
        if let v = AppDelegate.focusOverride {
            overrideValue = .bool(v)
        } else {
            overrideValue = .null
        }
        return .success(id: req.id, result: .object(["override": overrideValue]))
    }

    // MARK: - debug.app_focus.simulate_active

    private func appFocusSimulateActive(_ req: JSONRPCRequest) throws -> JSONRPCResponse {
        AppDelegate.shared?.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        return .success(id: req.id, result: .object([:]))
    }

    // MARK: - Private Helpers

    /// Recursively serialize ExternalTreeNode to JSONRPCValue, enriched with panel metadata.
    private func serializeTreeNode(_ node: ExternalTreeNode, engine: BonsplitLayoutEngine) -> JSONRPCValue {
        switch node {
        case .pane(let pane):
            var obj: [String: JSONRPCValue] = [
                "type": .string("pane"),
                "id": .string(pane.id),
                "frame": pixelRectToValue(pane.frame),
                "selected_tab_id": pane.selectedTabId.map { .string($0) } ?? .null,
                "tabs": .array(pane.tabs.map { tab in
                    .object([
                        "id": .string(tab.id),
                        "title": .string(tab.title),
                    ])
                }),
            ]

            // Enrich with panel metadata if the selected tab maps to a known panel
            if let selectedTabId = pane.selectedTabId,
               let tabUUID = UUID(uuidString: selectedTabId),
               let panelID = engine.panelID(for: TabID(uuid: tabUUID)) {
                if let terminal = panelManager.panel(for: panelID) {
                    obj["panel_type"] = .string("terminal")
                    obj["panel_id"] = .string(panelID.uuidString)
                    obj["title"] = .string(terminal.title)
                    obj["working_directory"] = terminal.workingDirectory.map { .string($0) } ?? .null
                    obj["git_branch"] = terminal.gitBranch.map { .string($0) } ?? .null
                    obj["shell_state"] = .string(String(describing: terminal.shellState))
                    // NSView-level introspection for diagnosing rendering issues
                    let view = terminal.surfaceView
                    obj["nsview_debug"] = .object([
                        "in_window": .bool(view.window != nil),
                        "hidden": .bool(view.isHiddenOrHasHiddenAncestor),
                        "is_first_responder": .bool(view.window?.firstResponder === view),
                        "view_frame": view.window != nil ? .object([
                            "x": .double(view.convert(view.bounds, to: nil).origin.x),
                            "y": .double(view.convert(view.bounds, to: nil).origin.y),
                            "width": .double(view.bounds.width),
                            "height": .double(view.bounds.height),
                        ]) : .null,
                    ])
                } else if let browser = panelManager.browserPanel(for: panelID) {
                    obj["panel_type"] = .string("browser")
                    obj["panel_id"] = .string(panelID.uuidString)
                    obj["title"] = .string(browser.title)
                } else if let markdown = panelManager.markdownPanel(for: panelID) {
                    obj["panel_type"] = .string("markdown")
                    obj["panel_id"] = .string(panelID.uuidString)
                    obj["title"] = .string(markdown.title)
                }
            }

            return .object(obj)

        case .split(let split):
            return .object([
                "type": .string("split"),
                "id": .string(split.id),
                "orientation": .string(split.orientation),
                "divider_position": .double(split.dividerPosition),
                "first": serializeTreeNode(split.first, engine: engine),
                "second": serializeTreeNode(split.second, engine: engine),
            ])
        }
    }

    private func pixelRectToValue(_ rect: PixelRect) -> JSONRPCValue {
        .object([
            "x": .double(rect.x),
            "y": .double(rect.y),
            "width": .double(rect.width),
            "height": .double(rect.height),
        ])
    }

    /// Count pixels that differ between two snapshots using Manhattan distance with threshold.
    private func countChangedPixels(previous: PanelSnapshotState, current: PanelSnapshotState) -> Int {
        // Dimension mismatch = incomparable
        guard previous.width == current.width,
              previous.height == current.height,
              previous.bytesPerRow == current.bytesPerRow else {
            return -1
        }

        let threshold = 8  // Ignore sub-perceptual jitter from Metal rendering
        var count = 0
        let byteCount = min(previous.rgba.count, current.rgba.count)

        previous.rgba.withUnsafeBytes { prevPtr in
            current.rgba.withUnsafeBytes { currPtr in
                guard let prevBase = prevPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let currBase = currPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

                var i = 0
                while i < byteCount {
                    // RGBA: compare R, G, B; skip A (index 3)
                    let dr = abs(Int(prevBase[i]) - Int(currBase[i]))
                    let dg = abs(Int(prevBase[i + 1]) - Int(currBase[i + 1]))
                    let db = abs(Int(prevBase[i + 2]) - Int(currBase[i + 2]))
                    if dr + dg + db > threshold {
                        count += 1
                    }
                    i += 4
                }
            }
        }

        return count
    }
}

// MARK: - Panel Snapshot State

struct PanelSnapshotState: Sendable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let rgba: Data
}

// MARK: - Helpers

private extension JSONRPCResponse {
    static func notAvailable(_ req: JSONRPCRequest) -> JSONRPCResponse {
        .failure(id: req.id, error: .internalError("Service unavailable"))
    }
}
