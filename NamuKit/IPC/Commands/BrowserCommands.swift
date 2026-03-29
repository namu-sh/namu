import Foundation

/// Handlers for the browser.* command namespace.
/// Uses BrowserRegistry to reach live BrowserControlling instances in NamuUI.
@MainActor
final class BrowserCommands {

    private let workspaceManager: WorkspaceManager
    private weak var panelManager: PanelManager?

    init(workspaceManager: WorkspaceManager, panelManager: PanelManager? = nil) {
        self.workspaceManager = workspaceManager
        self.panelManager = panelManager
    }

    // MARK: - Registration

    func register(in registry: CommandRegistry) {
        registry.register("browser.navigate")        { [weak self] req in try await self?.navigate(req)      ?? .notAvailable(req) }
        registry.register("browser.back")            { [weak self] req in try await self?.back(req)          ?? .notAvailable(req) }
        registry.register("browser.forward")         { [weak self] req in try await self?.forward(req)       ?? .notAvailable(req) }
        registry.register("browser.reload")          { [weak self] req in try await self?.reload(req)        ?? .notAvailable(req) }
        registry.register("browser.get_url")         { [weak self] req in try await self?.getURL(req)        ?? .notAvailable(req) }
        registry.register("browser.get_title")       { [weak self] req in try await self?.getTitle(req)      ?? .notAvailable(req) }
        registry.register("browser.execute_js")      { [weak self] req in try await self?.executeJS(req)     ?? .notAvailable(req) }
        registry.register("browser.click")           { [weak self] req in try await self?.click(req)         ?? .notAvailable(req) }
        registry.register("browser.type")            { [weak self] req in try await self?.type(req)          ?? .notAvailable(req) }
        registry.register("browser.hover")           { [weak self] req in try await self?.hover(req)         ?? .notAvailable(req) }
        registry.register("browser.get_text")        { [weak self] req in try await self?.getText(req)       ?? .notAvailable(req) }
        registry.register("browser.get_attribute")   { [weak self] req in try await self?.getAttribute(req)  ?? .notAvailable(req) }
        registry.register("browser.screenshot")          { [weak self] req in try await self?.screenshot(req)        ?? .notAvailable(req) }
        registry.register("browser.find_text")           { [weak self] req in try await self?.findText(req)          ?? .notAvailable(req) }
        registry.register("browser.wait_for_selector")   { [weak self] req in try await self?.waitForSelector(req)  ?? .notAvailable(req) }
        registry.register("browser.wait_for_navigation") { [weak self] req in try await self?.waitForNavigation(req) ?? .notAvailable(req) }
        registry.register("browser.dismiss_dialog")      { [weak self] req in try await self?.dismissDialog(req)    ?? .notAvailable(req) }
        registry.register("browser.console_logs")        { [weak self] req in try await self?.consoleLogs(req)      ?? .notAvailable(req) }
        registry.register("browser.get_cookie")          { [weak self] req in try await self?.getCookie(req)        ?? .notAvailable(req) }
        registry.register("browser.set_cookie")          { [weak self] req in try await self?.setCookie(req)        ?? .notAvailable(req) }
        registry.register("browser.delete_cookie")       { [weak self] req in try await self?.deleteCookie(req)     ?? .notAvailable(req) }
        registry.register("browser.get_storage")         { [weak self] req in try await self?.getStorage(req)       ?? .notAvailable(req) }
        registry.register("browser.set_storage")         { [weak self] req in try await self?.setStorage(req)       ?? .notAvailable(req) }
        registry.register("browser.clear_storage")       { [weak self] req in try await self?.clearStorage(req)     ?? .notAvailable(req) }
        registry.register("browser.set_viewport")        { [weak self] req in try await self?.setViewport(req)      ?? .notAvailable(req) }
        registry.register("browser.scroll")              { [weak self] req in try await self?.scroll(req)           ?? .notAvailable(req) }
        registry.register("browser.scroll_into_view")    { [weak self] req in try await self?.scrollIntoView(req)   ?? .notAvailable(req) }
        registry.register("browser.press")               { [weak self] req in try await self?.press(req)            ?? .notAvailable(req) }
        registry.register("browser.check")               { [weak self] req in try await self?.check(req)            ?? .notAvailable(req) }
        registry.register("browser.uncheck")             { [weak self] req in try await self?.uncheck(req)          ?? .notAvailable(req) }
        registry.register("browser.select")              { [weak self] req in try await self?.selectOption(req)     ?? .notAvailable(req) }
        registry.register("browser.frame.select")        { [weak self] req in try await self?.frameSelect(req)      ?? .notAvailable(req) }
        registry.register("browser.frame.main")          { [weak self] req in try await self?.frameMain(req)        ?? .notAvailable(req) }
        registry.register("browser.focus")               { [weak self] req in try await self?.focusElement(req)     ?? .notAvailable(req) }
        registry.register("browser.console.clear")       { [weak self] req in try await self?.consoleClear(req)     ?? .notAvailable(req) }
        registry.register("browser.download.wait")       { [weak self] req in try await self?.downloadWait(req)     ?? .notAvailable(req) }
        registry.register("browser.init_script")         { [weak self] req in try await self?.initScript(req)       ?? .notAvailable(req) }
        registry.register("browser.init_style")          { [weak self] req in try await self?.initStyle(req)        ?? .notAvailable(req) }
    }

    // MARK: - browser.navigate

    private func navigate(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let urlValue = params["url"], case .string(let urlStr) = urlValue, !urlStr.isEmpty else {
            throw JSONRPCError(code: -32602, message: "Missing required param: url")
        }
        let controller = try resolveBrowserController(params: params)
        controller.navigate(to: urlStr)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "url":        .string(urlStr)
        ]))
    }

    // MARK: - browser.back

    private func back(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let controller = try resolveBrowserController(params: req.params?.object ?? [:])
        controller.goBack()
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString)
        ]))
    }

    // MARK: - browser.forward

    private func forward(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let controller = try resolveBrowserController(params: req.params?.object ?? [:])
        controller.goForward()
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString)
        ]))
    }

    // MARK: - browser.reload

    private func reload(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let controller = try resolveBrowserController(params: req.params?.object ?? [:])
        controller.reload()
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString)
        ]))
    }

    // MARK: - browser.get_url

    private func getURL(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let controller = try resolveBrowserController(params: req.params?.object ?? [:])
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "url":        .string(controller.currentURL)
        ]))
    }

    // MARK: - browser.get_title

    private func getTitle(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let controller = try resolveBrowserController(params: req.params?.object ?? [:])
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "title":      .string(controller.currentTitle)
        ]))
    }

    // MARK: - browser.execute_js

    private func executeJS(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let scriptValue = params["script"], case .string(let script) = scriptValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: script")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.evaluateJS(script)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string(result)
        ]))
    }

    // MARK: - browser.click

    private func click(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let selValue = params["selector"], case .string(let selector) = selValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: selector")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.click(selector: selector)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string(result)
        ]))
    }

    // MARK: - browser.type

    private func type(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let selValue = params["selector"], case .string(let selector) = selValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: selector")
        }
        guard let textValue = params["text"], case .string(let text) = textValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: text")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.type(selector: selector, text: text)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string(result)
        ]))
    }

    // MARK: - browser.hover

    private func hover(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let selValue = params["selector"], case .string(let selector) = selValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: selector")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.hover(selector: selector)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string(result)
        ]))
    }

    // MARK: - browser.get_text

    private func getText(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let selValue = params["selector"], case .string(let selector) = selValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: selector")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.getText(selector: selector)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "text":       .string(result)
        ]))
    }

    // MARK: - browser.get_attribute

    private func getAttribute(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let selValue = params["selector"], case .string(let selector) = selValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: selector")
        }
        guard let attrValue = params["attribute"], case .string(let attribute) = attrValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: attribute")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.getAttribute(selector: selector, attribute: attribute)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "value":      .string(result)
        ]))
    }

    // MARK: - browser.screenshot

    private func screenshot(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let controller = try resolveBrowserController(params: req.params?.object ?? [:])
        let data = try await controller.takeScreenshot()
        let base64 = data.base64EncodedString()
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "data":       .string(base64),
            "encoding":   .string("base64"),
            "format":     .string("png")
        ]))
    }

    // MARK: - browser.find_text

    private func findText(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let textValue = params["text"], case .string(let text) = textValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: text")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.findText(text)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string(result)
        ]))
    }

    // MARK: - browser.wait_for_selector

    private func waitForSelector(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let selValue = params["selector"], case .string(let selector) = selValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: selector")
        }
        let timeout: TimeInterval
        switch params["timeout"] {
        case .some(.double(let n)): timeout = n
        case .some(.int(let n)):    timeout = TimeInterval(n)
        default:                    timeout = 5.0
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.waitForSelector(selector, timeout: timeout)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string(result)
        ]))
    }

    // MARK: - browser.wait_for_navigation

    private func waitForNavigation(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        let timeout: TimeInterval
        switch params["timeout"] {
        case .some(.double(let n)): timeout = n
        case .some(.int(let n)):    timeout = TimeInterval(n)
        default:                    timeout = 10.0
        }
        let controller = try resolveBrowserController(params: params)
        try await controller.waitForNavigation(timeout: timeout)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string("ok")
        ]))
    }

    // MARK: - browser.dismiss_dialog

    private func dismissDialog(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        let accept: Bool
        if let v = params["accept"], case .bool(let b) = v { accept = b } else { accept = true }
        let text: String?
        if let v = params["text"], case .string(let s) = v { text = s } else { text = nil }
        let controller = try resolveBrowserController(params: params)
        try await controller.dismissDialog(accept: accept, text: text)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string("ok")
        ]))
    }

    // MARK: - browser.console_logs

    private func consoleLogs(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let controller = try resolveBrowserController(params: req.params?.object ?? [:])
        let logs = try await controller.consoleLogs()
        let entries: [JSONRPCValue] = logs.map { msg in
            .object([
                "level": .string(msg.level),
                "args":  .array(msg.args.map { .string($0) }),
                "ts":    .double(msg.timestamp)
            ])
        }
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "logs":       .array(entries)
        ]))
    }

    // MARK: - browser.get_cookie

    private func getCookie(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        let urlArg: URL?
        if let v = params["url"], case .string(let s) = v { urlArg = URL(string: s) } else { urlArg = nil }
        let controller = try resolveBrowserController(params: params)
        let cookies = try await controller.getCookies(url: urlArg)
        let entries: [JSONRPCValue] = cookies.map { d in
            .object(d.mapValues { JSONRPCValue.string($0) })
        }
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "cookies":    .array(entries)
        ]))
    }

    // MARK: - browser.set_cookie

    private func setCookie(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        var props: [String: String] = [:]
        for key in ["name", "value", "domain", "path", "expires"] {
            if let v = params[key], case .string(let s) = v { props[key] = s }
        }
        guard props["name"] != nil, props["value"] != nil else {
            throw JSONRPCError(code: -32602, message: "Missing required params: name, value")
        }
        let controller = try resolveBrowserController(params: params)
        try await controller.setCookieProperties(props)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string("ok")
        ]))
    }

    // MARK: - browser.delete_cookie

    private func deleteCookie(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let nameVal = params["name"], case .string(let name) = nameVal else {
            throw JSONRPCError(code: -32602, message: "Missing required param: name")
        }
        guard let domainVal = params["domain"], case .string(let domain) = domainVal else {
            throw JSONRPCError(code: -32602, message: "Missing required param: domain")
        }
        let controller = try resolveBrowserController(params: params)
        try await controller.deleteCookie(name: name, domain: domain)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string("ok")
        ]))
    }

    // MARK: - browser.get_storage

    private func getStorage(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let keyVal = params["key"], case .string(let key) = keyVal else {
            throw JSONRPCError(code: -32602, message: "Missing required param: key")
        }
        let controller = try resolveBrowserController(params: params)
        let value = try await controller.getStorageItem(key: key)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "key":        .string(key),
            "value":      .string(value)
        ]))
    }

    // MARK: - browser.set_storage

    private func setStorage(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let keyVal = params["key"], case .string(let key) = keyVal else {
            throw JSONRPCError(code: -32602, message: "Missing required param: key")
        }
        guard let valVal = params["value"], case .string(let value) = valVal else {
            throw JSONRPCError(code: -32602, message: "Missing required param: value")
        }
        let controller = try resolveBrowserController(params: params)
        try await controller.setStorageItem(key: key, value: value)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string("ok")
        ]))
    }

    // MARK: - browser.clear_storage

    private func clearStorage(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let controller = try resolveBrowserController(params: req.params?.object ?? [:])
        try await controller.clearStorage()
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string("ok")
        ]))
    }

    // MARK: - browser.scroll

    private func scroll(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        let x: Double
        switch params["x"] {
        case .some(.double(let n)): x = n
        case .some(.int(let n)):    x = Double(n)
        default: throw JSONRPCError(code: -32602, message: "Missing required param: x")
        }
        let y: Double
        switch params["y"] {
        case .some(.double(let n)): y = n
        case .some(.int(let n)):    y = Double(n)
        default: throw JSONRPCError(code: -32602, message: "Missing required param: y")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.scroll(x: x, y: y)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string(result)
        ]))
    }

    // MARK: - browser.scroll_into_view

    private func scrollIntoView(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let selValue = params["selector"], case .string(let selector) = selValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: selector")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.scrollIntoView(selector: selector)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string(result)
        ]))
    }

    // MARK: - browser.press

    private func press(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let selValue = params["selector"], case .string(let selector) = selValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: selector")
        }
        guard let keyValue = params["key"], case .string(let key) = keyValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: key")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.press(selector: selector, key: key)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string(result)
        ]))
    }

    // MARK: - browser.check

    private func check(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let selValue = params["selector"], case .string(let selector) = selValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: selector")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.check(selector: selector)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string(result)
        ]))
    }

    // MARK: - browser.uncheck

    private func uncheck(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let selValue = params["selector"], case .string(let selector) = selValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: selector")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.uncheck(selector: selector)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string(result)
        ]))
    }

    // MARK: - browser.select

    private func selectOption(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let selValue = params["selector"], case .string(let selector) = selValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: selector")
        }
        guard let valValue = params["value"], case .string(let value) = valValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: value")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.selectOption(selector: selector, value: value)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string(result)
        ]))
    }

    // MARK: - browser.frame.select

    private func frameSelect(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let selValue = params["selector"], case .string(let selector) = selValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: selector")
        }
        let controller = try resolveBrowserController(params: params)
        controller.selectFrame(selector)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "frame":      .string(selector)
        ]))
    }

    // MARK: - browser.frame.main

    private func frameMain(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let controller = try resolveBrowserController(params: req.params?.object ?? [:])
        controller.selectFrame(nil)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "frame":      .string("main")
        ]))
    }

    // MARK: - browser.focus

    private func focusElement(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let selValue = params["selector"], case .string(let selector) = selValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: selector")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.focusElement(selector: selector)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string(result)
        ]))
    }

    // MARK: - browser.console.clear

    private func consoleClear(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let controller = try resolveBrowserController(params: req.params?.object ?? [:])
        controller.clearConsoleLogs()
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string("ok")
        ]))
    }

    // MARK: - browser.download.wait

    private func downloadWait(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        let timeout: TimeInterval
        switch params["timeout"] {
        case .some(.double(let n)): timeout = n
        case .some(.int(let n)):    timeout = TimeInterval(n)
        default:                    timeout = 30.0
        }
        let controller = try resolveBrowserController(params: params)
        let event = try await BrowserDownloadTracker.shared.waitForDownload(timeout: timeout)
        let outcome = event.outcome == .completed ? "completed" : "failed"
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "outcome":    .string(outcome),
            "filename":   .string(event.filename ?? ""),
            "error":      .string(event.error?.localizedDescription ?? "")
        ]))
    }

    // MARK: - browser.init_script

    private func initScript(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let scriptValue = params["script"], case .string(let script) = scriptValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: script")
        }
        let controller = try resolveBrowserController(params: params)
        controller.addInitScript(script)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string("ok")
        ]))
    }

    // MARK: - browser.init_style

    private func initStyle(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let cssValue = params["css"], case .string(let css) = cssValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: css")
        }
        let controller = try resolveBrowserController(params: params)
        controller.addInitStyle(css)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string("ok")
        ]))
    }

    // MARK: - browser.set_viewport

    private func setViewport(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        let width: Int
        switch params["width"] {
        case .some(.int(let n)):    width = n
        case .some(.double(let n)): width = Int(n)
        default: throw JSONRPCError(code: -32602, message: "Missing required param: width")
        }
        let height: Int
        switch params["height"] {
        case .some(.int(let n)):    height = n
        case .some(.double(let n)): height = Int(n)
        default: throw JSONRPCError(code: -32602, message: "Missing required param: height")
        }
        let controller = try resolveBrowserController(params: params)
        try await controller.setViewportSize(width: width, height: height)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "width":      .int(width),
            "height":     .int(height)
        ]))
    }

    // MARK: - Private helpers

    /// Resolve a live BrowserControlling for the requested surface.
    /// Prefers explicit surface_id, falls back to focused pane, then any registered browser.
    private func resolveBrowserController(params: [String: JSONRPCValue]) throws -> any BrowserControlling {
        // Explicit surface_id
        if let sidValue = params["surface_id"], case .string(let sidStr) = sidValue,
           let sid = UUID(uuidString: sidStr) {
            guard isBrowserPane(paneID: sid) else {
                throw JSONRPCError(code: -32001, message: "Surface is not a browser pane")
            }
            guard let controller = BrowserRegistry.shared.controller(for: sid) else {
                throw JSONRPCError(code: -32001, message: "Browser surface not available")
            }
            return controller
        }

        // Focused pane
        if let wsID = workspaceManager.selectedWorkspaceID,
           let focusedID = panelManager?.focusedPanelID(in: wsID),
           isBrowserPane(paneID: focusedID) {
            if let controller = BrowserRegistry.shared.controller(for: focusedID) {
                return controller
            }
        }

        // Any registered browser
        if let controller = BrowserRegistry.shared.resolve(paneID: nil) {
            return controller
        }

        throw JSONRPCError(code: -32001, message: "No browser surface available")
    }

    private func isBrowserPane(paneID: UUID) -> Bool {
        // Browser panel detection — currently only terminal panels exist.
        // When browser panels are implemented, check via BrowserRegistry.
        BrowserRegistry.shared.controller(for: paneID) != nil
    }
}

// MARK: - Helpers

private extension JSONRPCResponse {
    static func notAvailable(_ req: JSONRPCRequest) -> JSONRPCResponse {
        .failure(id: req.id, error: .internalError("Service unavailable"))
    }
}
