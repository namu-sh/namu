import XCTest
@testable import Namu

@MainActor
final class SessionPersistenceTests: XCTestCase {

    // MARK: - SessionSnapshot version

    func testSnapshotCurrentVersion() {
        let snapshot = SessionSnapshot()
        XCTAssertEqual(snapshot.version, SessionSnapshot.currentVersion)
    }

    // MARK: - Codable round-trip

    func testSnapshotCodableRoundTrip() throws {
        let paneSnap = PaneSnapshot(
            id: UUID(),
            panelType: .terminal,
            workingDirectory: "/tmp",
            scrollbackFile: nil
        )
        let layout = WorkspaceLayoutSnapshot.pane(paneSnap)
        let wsSnap = WorkspaceSnapshot(
            id: UUID(),
            title: "Test WS",
            order: 0,
            isPinned: false,
            customTitle: "My Custom Title",
            processTitle: "vim",
            layout: layout,
            activePanelID: nil
        )
        let windowSnap = WindowSnapshot(
            windowID: UUID(),
            workspaces: [wsSnap],
            selectedWorkspaceID: wsSnap.id
        )
        let snapshot = SessionSnapshot(windows: [windowSnap])

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(snapshot)
        let decoded = try decoder.decode(SessionSnapshot.self, from: data)

        XCTAssertEqual(decoded.version, SessionSnapshot.currentVersion)
        XCTAssertEqual(decoded.windows.count, 1)
        let decodedWS = decoded.windows[0].workspaces[0]
        XCTAssertEqual(decodedWS.title, "Test WS")
        XCTAssertEqual(decodedWS.customTitle, "My Custom Title")
        XCTAssertEqual(decodedWS.processTitle, "vim")
        XCTAssertEqual(decodedWS.order, 0)
        XCTAssertFalse(decodedWS.isPinned)
    }

    func testSnapshotPreservesWorkspaceOrder() throws {
        let snapshots = (0..<3).map { i in
            WorkspaceSnapshot(
                id: UUID(),
                title: "WS \(i)",
                order: i,
                isPinned: false,
                customTitle: nil,
                processTitle: nil,
                layout: .pane(PaneSnapshot(id: UUID(), panelType: .terminal, workingDirectory: nil, scrollbackFile: nil)),
                activePanelID: nil
            )
        }
        let windowSnap = WindowSnapshot(windowID: UUID(), workspaces: snapshots, selectedWorkspaceID: snapshots[0].id)
        let snapshot = SessionSnapshot(windows: [windowSnap])

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)

        let decodedWorkspaces = decoded.windows[0].workspaces
        XCTAssertEqual(decodedWorkspaces.count, 3)
        for i in 0..<3 {
            XCTAssertEqual(decodedWorkspaces[i].order, i)
        }
    }

    func testSnapshotPreservesScrollbackFile() throws {
        let scrollbackPath = "/tmp/scrollback_\(UUID().uuidString).txt"
        let paneSnap = PaneSnapshot(
            id: UUID(),
            panelType: .terminal,
            workingDirectory: "/home/user",
            scrollbackFile: scrollbackPath
        )
        let layout = WorkspaceLayoutSnapshot.pane(paneSnap)
        let wsSnap = WorkspaceSnapshot(
            id: UUID(),
            title: "WS",
            order: 0,
            isPinned: false,
            customTitle: nil,
            processTitle: nil,
            layout: layout,
            activePanelID: nil
        )
        let windowSnap = WindowSnapshot(windowID: UUID(), workspaces: [wsSnap], selectedWorkspaceID: wsSnap.id)
        let snapshot = SessionSnapshot(windows: [windowSnap])

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionSnapshot.self, from: data)

        guard case .pane(let decodedPane) = decoded.windows[0].workspaces[0].layout else {
            return XCTFail("Expected pane layout")
        }
        XCTAssertEqual(decodedPane.scrollbackFile, scrollbackPath)
        XCTAssertEqual(decodedPane.workingDirectory, "/home/user")
    }

    // MARK: - Workspace Codable

    func testWorkspaceCodablePreservesCustomTitle() throws {
        var ws = Workspace(title: "Original", order: 0)
        ws.setCustomTitle("My Custom Title")

        let data = try JSONEncoder().encode(ws)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)
        XCTAssertEqual(decoded.customTitle, "My Custom Title")
        XCTAssertEqual(decoded.title, "My Custom Title")
    }

    func testWorkspaceCodablePreservesPinned() throws {
        var ws = Workspace(title: "Pinned", order: 1)
        ws.isPinned = true

        let data = try JSONEncoder().encode(ws)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)
        XCTAssertTrue(decoded.isPinned)
    }

    // MARK: - SessionPersistence lifecycle (no file I/O)

    func testSaveStatusInitiallyIdle() {
        let wm = WorkspaceManager()
        let pm = PanelManager(workspaceManager: wm)
        let sp = SessionPersistence(workspaceManager: wm, panelManager: pm)
        XCTAssertEqual(sp.saveStatus, .idle)
    }

    func testStartStopAutosaveDoesNotCrash() {
        let wm = WorkspaceManager()
        let pm = PanelManager(workspaceManager: wm)
        let sp = SessionPersistence(workspaceManager: wm, panelManager: pm)
        sp.startAutosave()
        sp.stopAutosave()
    }
}
