import Foundation

/// Handlers for the sidebar.* command namespace.
/// Allows shell integration to push PR status, custom metadata, and markdown blocks
/// into the sidebar for the active or specified workspace.
@MainActor
final class SidebarCommands {

    private let workspaceManager: WorkspaceManager
    private let sidebarViewModel: SidebarViewModel

    init(workspaceManager: WorkspaceManager, sidebarViewModel: SidebarViewModel) {
        self.workspaceManager = workspaceManager
        self.sidebarViewModel = sidebarViewModel
    }

    // MARK: - Registration

    func register(in registry: CommandRegistry) {
        registry.register("sidebar.report_pr")       { [weak self] req in try await self?.reportPR(req) ?? .notAvailable(req) }
        registry.register("sidebar.report_metadata") { [weak self] req in try await self?.reportMetadata(req) ?? .notAvailable(req) }
        registry.register("sidebar.report_markdown") { [weak self] req in try await self?.reportMarkdown(req) ?? .notAvailable(req) }
        registry.register("sidebar.log")             { [weak self] req in try await self?.log(req) ?? .notAvailable(req) }
        registry.register("sidebar.clear_log")       { [weak self] req in try await self?.clearLog(req) ?? .notAvailable(req) }
        registry.register("sidebar.list_log")        { [weak self] req in try await self?.listLog(req) ?? .notAvailable(req) }
        registry.register("sidebar.set_status")      { [weak self] req in try await self?.setStatus(req) ?? .notAvailable(req) }
        registry.register("sidebar.clear_status")    { [weak self] req in try await self?.clearStatus(req) ?? .notAvailable(req) }
        registry.register("sidebar.list_status")     { [weak self] req in try await self?.listStatus(req) ?? .notAvailable(req) }
        registry.register("sidebar.set_progress")    { [weak self] req in try await self?.setProgress(req) ?? .notAvailable(req) }
        registry.register("sidebar.clear_progress")  { [weak self] req in try await self?.clearProgress(req) ?? .notAvailable(req) }
    }

    // MARK: - sidebar.report_pr
    //
    // Update pull request info for a workspace.
    // Params:
    //   workspace_id (string, optional) — defaults to selected workspace
    //   number       (int, required)    — PR number
    //   state        (string, required) — "open", "merged", or "closed"
    //   url          (string, required) — PR URL
    //   branch       (string, required) — source branch
    //   checks       (string, optional) — checks summary string e.g. "3/5 passing"

    private func reportPR(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        let workspaceID = resolveWorkspaceID(params)

        guard let numberValue = params["number"], case .int(let number) = numberValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: number")
        }
        guard let stateValue = params["state"], case .string(let stateStr) = stateValue,
              let state = PRState(rawValue: stateStr) else {
            throw JSONRPCError(code: -32602, message: "Missing or invalid param: state (must be open/merged/closed)")
        }
        guard let urlValue = params["url"], case .string(let url) = urlValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: url")
        }
        guard let branchValue = params["branch"], case .string(let branch) = branchValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: branch")
        }

        let checksStatus: PRChecksStatus?
        if let checksValue = params["checks"], case .string(let checks) = checksValue, !checks.isEmpty {
            checksStatus = PRChecksStatus(rawValue: checks) ?? .none
        } else {
            checksStatus = nil
        }

        let pr = PullRequestDisplay(
            number: number,
            state: state,
            url: url,
            branch: branch,
            checksStatus: checksStatus
        )

        updateMetadata(for: workspaceID) { meta in
            // Replace existing PR with same number, or append
            if let idx = meta.pullRequests.firstIndex(where: { $0.number == number }) {
                meta.pullRequests[idx] = pr
            } else {
                meta.pullRequests.append(pr)
            }
        }

        return .success(id: req.id, result: .object([
            "workspace_id": .string(workspaceID.uuidString),
            "number": .int(number),
            "state": .string(state.rawValue)
        ]))
    }

    // MARK: - sidebar.report_metadata
    //
    // Update custom key-value metadata entries for a workspace.
    // Params:
    //   workspace_id (string, optional) — defaults to selected workspace
    //   entries      (object, required) — key-value pairs to merge

    private func reportMetadata(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        let workspaceID = resolveWorkspaceID(params)

        guard let entriesValue = params["entries"], case .object(let entriesObj) = entriesValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: entries (object)")
        }

        let newEntries: [(String, String)] = entriesObj.compactMap { key, value in
            guard case .string(let str) = value else { return nil }
            return (key, str)
        }.sorted(by: { $0.0 < $1.0 })

        updateMetadata(for: workspaceID) { meta in
            // Merge: overwrite existing keys, keep others
            var dict = Dictionary(uniqueKeysWithValues: meta.metadataEntries)
            for (k, v) in newEntries {
                dict[k] = v
            }
            meta.metadataEntries = dict.sorted(by: { $0.key < $1.key }).map { ($0.key, $0.value) }
        }

        return .success(id: req.id, result: .object([
            "workspace_id": .string(workspaceID.uuidString),
            "count": .int(newEntries.count)
        ]))
    }

    // MARK: - sidebar.report_markdown
    //
    // Update markdown blocks displayed in the sidebar for a workspace.
    // Params:
    //   workspace_id (string, optional) — defaults to selected workspace
    //   blocks       (array of strings) — replaces existing markdown blocks

    private func reportMarkdown(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        let workspaceID = resolveWorkspaceID(params)

        guard let blocksValue = params["blocks"], case .array(let blocksArr) = blocksValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: blocks (array)")
        }

        let blocks: [String] = blocksArr.compactMap { value in
            guard case .string(let s) = value else { return nil }
            return s
        }

        updateMetadata(for: workspaceID) { meta in
            meta.markdownBlocks = blocks
        }

        return .success(id: req.id, result: .object([
            "workspace_id": .string(workspaceID.uuidString),
            "count": .int(blocks.count)
        ]))
    }

    // MARK: - sidebar.log
    //
    // Append a structured log entry to the workspace's log.
    // Params:
    //   message      (string, required)  — log message text
    //   level        (string, optional)  — info|progress|success|warning|error (default: info)
    //   source       (string, optional)  — originating tool or process name
    //   workspace_id (string, optional)  — defaults to selected workspace

    private func log(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        guard let msgValue = params["message"], case .string(let message) = msgValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: message")
        }

        let level: SidebarLogLevel
        if let lvlValue = params["level"], case .string(let lvlStr) = lvlValue,
           let parsed = SidebarLogLevel(rawValue: lvlStr) {
            level = parsed
        } else {
            level = .info
        }

        let source: String?
        if let srcValue = params["source"], case .string(let s) = srcValue, !s.isEmpty {
            source = s
        } else {
            source = nil
        }

        let workspaceID = resolveWorkspaceID(params)
        let entry = SidebarLogEntry(message: message, level: level, source: source, timestamp: Date())

        updateMetadata(for: workspaceID) { meta in
            meta.logEntries.append(entry)
            if meta.logEntries.count > SidebarMetadata.maxLogEntries {
                meta.logEntries.removeFirst(meta.logEntries.count - SidebarMetadata.maxLogEntries)
            }
            meta.latestLog = message
            meta.logLevel = level.rawValue
        }

        return .success(id: req.id, result: .object([
            "workspace_id": .string(workspaceID.uuidString),
            "level":        .string(level.rawValue),
            "message":      .string(message)
        ]))
    }

    // MARK: - sidebar.clear_log
    //
    // Clear all log entries for a workspace.
    // Params:
    //   workspace_id (string, optional) — defaults to selected workspace

    private func clearLog(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        let workspaceID = resolveWorkspaceID(params)

        var cleared = 0
        updateMetadata(for: workspaceID) { meta in
            cleared = meta.logEntries.count
            meta.logEntries = []
            meta.latestLog = nil
            meta.logLevel = nil
        }

        return .success(id: req.id, result: .object([
            "workspace_id": .string(workspaceID.uuidString),
            "cleared":      .int(cleared)
        ]))
    }

    // MARK: - sidebar.list_log
    //
    // Return log entries for a workspace, newest first.
    // Params:
    //   workspace_id (string, optional) — defaults to selected workspace
    //   limit        (int, optional)    — max entries to return (default: all)

    private func listLog(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        let workspaceID = resolveWorkspaceID(params)

        let limit: Int?
        if let limValue = params["limit"], case .int(let n) = limValue, n > 0 {
            limit = n
        } else {
            limit = nil
        }

        let meta = sidebarViewModel.currentMetadata(for: workspaceID)
        var entries = meta.logEntries.reversed() as [SidebarLogEntry]
        if let limit {
            entries = Array(entries.prefix(limit))
        }

        let items: [JSONRPCValue] = entries.map { entry in
            var obj: [String: JSONRPCValue] = [
                "message":   .string(entry.message),
                "level":     .string(entry.level.rawValue),
                "timestamp": .double(entry.timestamp.timeIntervalSince1970)
            ]
            if let src = entry.source {
                obj["source"] = .string(src)
            } else {
                obj["source"] = .null
            }
            return .object(obj)
        }

        return .success(id: req.id, result: .object([
            "workspace_id": .string(workspaceID.uuidString),
            "entries":      .array(items),
            "count":        .int(items.count)
        ]))
    }

    // MARK: - sidebar.set_status
    //
    // Create or update a status entry for a workspace.
    // Params:
    //   key          (string, required)  — unique identifier for this status entry
    //   value        (string, required)  — display text
    //   icon         (string, optional)  — SF Symbol name or emoji
    //   color        (string, optional)  — hex color #RRGGBB
    //   url          (string, optional)  — clickable link URL
    //   priority     (int, optional)     — sort order, higher = shown first (default: 0)
    //   format       (string, optional)  — "plain" or "markdown" (default: "plain")
    //   workspace_id (string, optional)  — defaults to selected workspace

    private func setStatus(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        guard let keyValue = params["key"], case .string(let key) = keyValue, !key.isEmpty else {
            throw JSONRPCError(code: -32602, message: "Missing required param: key")
        }
        guard let valValue = params["value"], case .string(let value) = valValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: value")
        }

        let icon: String?
        if let iconValue = params["icon"], case .string(let s) = iconValue, !s.isEmpty {
            icon = s
        } else {
            icon = nil
        }

        let color: String?
        if let colorValue = params["color"], case .string(let s) = colorValue, !s.isEmpty {
            color = s
        } else {
            color = nil
        }

        let url: URL?
        if let urlValue = params["url"], case .string(let s) = urlValue, !s.isEmpty {
            url = URL(string: s)
        } else {
            url = nil
        }

        let priority: Int
        if let priValue = params["priority"], case .int(let n) = priValue {
            priority = n
        } else {
            priority = 0
        }

        let format: SidebarMetadataFormat
        if let fmtValue = params["format"], case .string(let s) = fmtValue,
           let parsed = SidebarMetadataFormat(rawValue: s) {
            format = parsed
        } else {
            format = .plain
        }

        let workspaceID = resolveWorkspaceID(params)
        let entry = SidebarStatusEntry(
            key: key,
            value: value,
            icon: icon,
            color: color,
            url: url,
            priority: priority,
            format: format,
            timestamp: Date()
        )

        updateMetadata(for: workspaceID) { meta in
            meta.statusEntries[key] = entry
        }

        return .success(id: req.id, result: .object([
            "workspace_id": .string(workspaceID.uuidString),
            "key":          .string(key),
            "value":        .string(value)
        ]))
    }

    // MARK: - sidebar.clear_status
    //
    // Remove a status entry for a workspace.
    // Params:
    //   key          (string, required) — unique identifier of the entry to remove
    //   workspace_id (string, optional) — defaults to selected workspace

    private func clearStatus(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        guard let keyValue = params["key"], case .string(let key) = keyValue, !key.isEmpty else {
            throw JSONRPCError(code: -32602, message: "Missing required param: key")
        }

        let workspaceID = resolveWorkspaceID(params)
        var removed = false

        updateMetadata(for: workspaceID) { meta in
            removed = meta.statusEntries.removeValue(forKey: key) != nil
        }

        return .success(id: req.id, result: .object([
            "workspace_id": .string(workspaceID.uuidString),
            "key":          .string(key),
            "removed":      .bool(removed)
        ]))
    }

    // MARK: - sidebar.list_status
    //
    // Return all status entries for a workspace, sorted by priority then timestamp.
    // Params:
    //   workspace_id (string, optional) — defaults to selected workspace

    private func listStatus(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        let workspaceID = resolveWorkspaceID(params)

        let meta = sidebarViewModel.currentMetadata(for: workspaceID)
        let sorted = meta.statusEntries.values
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                return lhs.timestamp > rhs.timestamp
            }

        let items: [JSONRPCValue] = sorted.map { entry in
            var obj: [String: JSONRPCValue] = [
                "key":       .string(entry.key),
                "value":     .string(entry.value),
                "priority":  .int(entry.priority),
                "format":    .string(entry.format.rawValue),
                "timestamp": .double(entry.timestamp.timeIntervalSince1970)
            ]
            obj["icon"]  = entry.icon.map { .string($0) } ?? .null
            obj["color"] = entry.color.map { .string($0) } ?? .null
            obj["url"]   = entry.url.map { .string($0.absoluteString) } ?? .null
            return .object(obj)
        }

        return .success(id: req.id, result: .object([
            "workspace_id": .string(workspaceID.uuidString),
            "entries":      .array(items),
            "count":        .int(items.count)
        ]))
    }

        // MARK: - Helpers

    private func resolveWorkspaceID(_ params: [String: JSONRPCValue]) -> UUID {
        if let wsValue = params["workspace_id"],
           case .string(let wsStr) = wsValue,
           let id = UUID(uuidString: wsStr) {
            return id
        }
        // WorkspaceManager prevents deleting the last workspace, so .first should
        // always succeed. The UUID() fallback is an unreachable last resort.
        return workspaceManager.selectedWorkspaceID
            ?? workspaceManager.workspaces.first?.id
            ?? UUID()
    }

    // MARK: - sidebar.set_progress

    private func setProgress(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]

        guard let valParam = params["value"] else {
            throw JSONRPCError(code: -32602, message: "Missing required param: value (0.0-1.0)")
        }
        let value: Double
        switch valParam {
        case .int(let i):    value = Double(i)
        case .double(let d): value = d
        default:
            throw JSONRPCError(code: -32602, message: "value must be a number between 0.0 and 1.0")
        }
        guard (0.0...1.0).contains(value) else {
            throw JSONRPCError(code: -32602, message: "value must be between 0.0 and 1.0")
        }

        let label: String?
        if let lbl = params["label"], case .string(let s) = lbl, !s.isEmpty {
            label = s
        } else {
            label = nil
        }

        let workspaceID = resolveWorkspaceID(params)
        updateMetadata(for: workspaceID) { meta in
            meta.progress = value
            meta.progressLabel = label
        }

        return .success(id: req.id, result: .object([
            "workspace_id": .string(workspaceID.uuidString),
            "value": .double(value),
            "label": label.map { .string($0) } ?? .null,
        ]))
    }

    // MARK: - sidebar.clear_progress

    private func clearProgress(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        let workspaceID = resolveWorkspaceID(params)

        updateMetadata(for: workspaceID) { meta in
            meta.progress = nil
            meta.progressLabel = nil
        }

        return .success(id: req.id, result: .object([
            "workspace_id": .string(workspaceID.uuidString),
            "cleared": .bool(true),
        ]))
    }

    // MARK: - Private helpers

    private func updateMetadata(for workspaceID: UUID, transform: (inout SidebarMetadata) -> Void) {
        var meta = sidebarViewModel.currentMetadata(for: workspaceID)
        transform(&meta)
        sidebarViewModel.updateMetadata(meta, for: workspaceID)
    }
}

// MARK: - Helpers

private extension JSONRPCResponse {
    static func notAvailable(_ req: JSONRPCRequest) -> JSONRPCResponse {
        .failure(id: req.id, error: .internalError("Service unavailable"))
    }
}
