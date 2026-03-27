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

        let checksStatus: String?
        if let checksValue = params["checks"], case .string(let checks) = checksValue, !checks.isEmpty {
            checksStatus = checks
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

    // MARK: - Helpers

    private func resolveWorkspaceID(_ params: [String: JSONRPCValue]) -> UUID {
        if let wsValue = params["workspace_id"],
           case .string(let wsStr) = wsValue,
           let id = UUID(uuidString: wsStr) {
            return id
        }
        return workspaceManager.selectedWorkspaceID
            ?? workspaceManager.workspaces.first?.id
            ?? UUID()
    }

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
