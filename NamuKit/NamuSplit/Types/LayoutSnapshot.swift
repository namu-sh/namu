import Foundation

// MARK: - Pixel Coordinates

/// Pixel rectangle for external consumption
struct PixelRect: Codable, Sendable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(from cgRect: CGRect) {
        self.x = Double(cgRect.origin.x)
        self.y = Double(cgRect.origin.y)
        self.width = Double(cgRect.size.width)
        self.height = Double(cgRect.size.height)
    }
}

// MARK: - Pane Geometry

/// Geometry for a single pane
struct PaneGeometry: Codable, Sendable, Equatable {
    let paneId: String
    let frame: PixelRect
    let selectedTabId: String?
    let tabIds: [String]

    init(paneId: String, frame: PixelRect, selectedTabId: String?, tabIds: [String]) {
        self.paneId = paneId
        self.frame = frame
        self.selectedTabId = selectedTabId
        self.tabIds = tabIds
    }
}

// MARK: - Layout Snapshot

/// Full tree snapshot with pixel coordinates
struct LayoutSnapshot: Codable, Sendable, Equatable {
    let containerFrame: PixelRect
    let panes: [PaneGeometry]
    let focusedPaneId: String?
    let timestamp: TimeInterval

    init(containerFrame: PixelRect, panes: [PaneGeometry], focusedPaneId: String?, timestamp: TimeInterval) {
        self.containerFrame = containerFrame
        self.panes = panes
        self.focusedPaneId = focusedPaneId
        self.timestamp = timestamp
    }
}

// MARK: - External Tree Representation

/// External representation of a tab
struct ExternalTab: Codable, Sendable, Equatable {
    let id: String
    let title: String

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// External representation of a pane node
struct ExternalPaneNode: Codable, Sendable, Equatable {
    let id: String
    let frame: PixelRect
    let tabs: [ExternalTab]
    let selectedTabId: String?

    init(id: String, frame: PixelRect, tabs: [ExternalTab], selectedTabId: String?) {
        self.id = id
        self.frame = frame
        self.tabs = tabs
        self.selectedTabId = selectedTabId
    }
}

/// External representation of a split node
struct ExternalSplitNode: Codable, Sendable, Equatable {
    let id: String
    let orientation: String  // "horizontal" or "vertical"
    let dividerPosition: Double  // 0.0-1.0
    let first: ExternalTreeNode
    let second: ExternalTreeNode

    init(id: String, orientation: String, dividerPosition: Double, first: ExternalTreeNode, second: ExternalTreeNode) {
        self.id = id
        self.orientation = orientation
        self.dividerPosition = dividerPosition
        self.first = first
        self.second = second
    }
}

/// External representation of the split tree
indirect enum ExternalTreeNode: Codable, Sendable, Equatable {
    case pane(ExternalPaneNode)
    case split(ExternalSplitNode)

    private enum CodingKeys: String, CodingKey {
        case type
        case pane
        case split
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "pane":
            let pane = try container.decode(ExternalPaneNode.self, forKey: .pane)
            self = .pane(pane)
        case "split":
            let split = try container.decode(ExternalSplitNode.self, forKey: .split)
            self = .split(split)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown type: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .pane(let paneNode):
            try container.encode("pane", forKey: .type)
            try container.encode(paneNode, forKey: .pane)
        case .split(let splitNode):
            try container.encode("split", forKey: .type)
            try container.encode(splitNode, forKey: .split)
        }
    }
}
