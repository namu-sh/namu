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
        registry.register("browser.devtools.toggle")     { [weak self] req in try await self?.devToolsToggle(req)   ?? .notAvailable(req) }
        registry.register("browser.devtools.console")    { [weak self] req in try await self?.devToolsConsole(req)  ?? .notAvailable(req) }

        // US-017: expanded command set
        registry.register("browser.dblclick")            { [weak self] req in try await self?.dblclick(req)         ?? .notAvailable(req) }
        registry.register("browser.fill")                { [weak self] req in try await self?.fill(req)             ?? .notAvailable(req) }
        registry.register("browser.keydown")             { [weak self] req in try await self?.keydown(req)          ?? .notAvailable(req) }
        registry.register("browser.keyup")               { [weak self] req in try await self?.keyup(req)            ?? .notAvailable(req) }
        registry.register("browser.get.html")            { [weak self] req in try await self?.getHTML(req)          ?? .notAvailable(req) }
        registry.register("browser.get.value")           { [weak self] req in try await self?.getValue(req)         ?? .notAvailable(req) }
        registry.register("browser.get.count")           { [weak self] req in try await self?.getCount(req)         ?? .notAvailable(req) }
        registry.register("browser.get.box")             { [weak self] req in try await self?.getBox(req)           ?? .notAvailable(req) }
        registry.register("browser.get.styles")          { [weak self] req in try await self?.getStyles(req)        ?? .notAvailable(req) }
        registry.register("browser.is.visible")          { [weak self] req in try await self?.isVisible(req)        ?? .notAvailable(req) }
        registry.register("browser.is.enabled")          { [weak self] req in try await self?.isEnabled(req)        ?? .notAvailable(req) }
        registry.register("browser.is.checked")          { [weak self] req in try await self?.isChecked(req)        ?? .notAvailable(req) }
        registry.register("browser.find.role")           { [weak self] req in try await self?.findRole(req)         ?? .notAvailable(req) }
        registry.register("browser.find.text")           { [weak self] req in try await self?.findByText(req)       ?? .notAvailable(req) }
        registry.register("browser.find.label")          { [weak self] req in try await self?.findByLabel(req)      ?? .notAvailable(req) }
        registry.register("browser.find.placeholder")    { [weak self] req in try await self?.findByPlaceholder(req) ?? .notAvailable(req) }
        registry.register("browser.find.alt")            { [weak self] req in try await self?.findByAlt(req)        ?? .notAvailable(req) }
        registry.register("browser.find.title")          { [weak self] req in try await self?.findByTitle(req)      ?? .notAvailable(req) }
        registry.register("browser.find.testid")         { [weak self] req in try await self?.findByTestId(req)     ?? .notAvailable(req) }
        registry.register("browser.find.first")          { [weak self] req in try await self?.findFirst(req)        ?? .notAvailable(req) }
        registry.register("browser.find.last")           { [weak self] req in try await self?.findLast(req)         ?? .notAvailable(req) }
        registry.register("browser.find.nth")            { [weak self] req in try await self?.findNth(req)          ?? .notAvailable(req) }
        registry.register("browser.dialog.accept")       { [weak self] req in try await self?.dialogAccept(req)     ?? .notAvailable(req) }
        registry.register("browser.dialog.dismiss")      { [weak self] req in try await self?.dialogDismiss(req)    ?? .notAvailable(req) }
        registry.register("browser.cookies.clear")       { [weak self] req in try await self?.cookiesClear(req)     ?? .notAvailable(req) }
        registry.register("browser.tab.new")             { [weak self] req in try await self?.tabNew(req)           ?? .notAvailable(req) }
        registry.register("browser.tab.list")            { [weak self] req in try await self?.tabList(req)          ?? .notAvailable(req) }
        registry.register("browser.tab.switch")          { [weak self] req in try await self?.tabSwitch(req)        ?? .notAvailable(req) }
        registry.register("browser.tab.close")           { [weak self] req in try await self?.tabClose(req)         ?? .notAvailable(req) }
        registry.register("browser.console.list")        { [weak self] req in try await self?.consoleList(req)      ?? .notAvailable(req) }
        registry.register("browser.errors.list")         { [weak self] req in try await self?.errorsList(req)       ?? .notAvailable(req) }
        registry.register("browser.highlight")           { [weak self] req in try await self?.highlight(req)        ?? .notAvailable(req) }
        registry.register("browser.state.save")          { [weak self] req in try await self?.stateSave(req)        ?? .notAvailable(req) }
        registry.register("browser.state.load")          { [weak self] req in try await self?.stateLoad(req)        ?? .notAvailable(req) }
        registry.register("browser.viewport.set")        { [weak self] req in try await self?.setViewport(req)      ?? .notAvailable(req) }
        registry.register("browser.network.requests")    { [weak self] req in try await self?.networkRequests(req)  ?? .notAvailable(req) }

        // US-018: expanded command set
        registry.register("browser.snapshot")            { [weak self] req in try await self?.snapshot(req)          ?? .notAvailable(req) }
        registry.register("browser.geolocation.set")     { [weak self] req in try await self?.geolocationSet(req)    ?? .notAvailable(req) }
        registry.register("browser.offline.set")         { [weak self] req in try await self?.offlineSet(req)        ?? .notAvailable(req) }
        registry.register("browser.trace.start")         { [weak self] req in try await self?.traceStart(req)        ?? .notAvailable(req) }
        registry.register("browser.trace.stop")          { [weak self] req in try await self?.traceStop(req)         ?? .notAvailable(req) }
        registry.register("browser.input_mouse")         { [weak self] req in try await self?.inputMouse(req)        ?? .notAvailable(req) }
        registry.register("browser.input_keyboard")      { [weak self] req in try await self?.inputKeyboard(req)     ?? .notAvailable(req) }
        registry.register("browser.input_touch")         { [weak self] req in try await self?.inputTouch(req)        ?? .notAvailable(req) }
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

    // MARK: - browser.devtools.toggle

    private func devToolsToggle(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let controller = try resolveBrowserController(params: req.params?.object ?? [:])
        controller.toggleDeveloperTools()
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string("ok")
        ]))
    }

    // MARK: - browser.devtools.console

    private func devToolsConsole(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let controller = try resolveBrowserController(params: req.params?.object ?? [:])
        controller.showDeveloperToolsConsole()
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

    // MARK: - US-017 handlers

    // MARK: browser.dblclick

    private func dblclick(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let selValue = params["selector"], case .string(let selector) = selValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: selector")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.dblclick(selector: selector)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string(result)
        ]))
    }

    // MARK: browser.fill

    private func fill(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let selValue = params["selector"], case .string(let selector) = selValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: selector")
        }
        guard let textValue = params["text"], case .string(let text) = textValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: text")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.fill(selector: selector, text: text)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string(result)
        ]))
    }

    // MARK: browser.keydown

    private func keydown(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let selValue = params["selector"], case .string(let selector) = selValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: selector")
        }
        guard let keyValue = params["key"], case .string(let key) = keyValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: key")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.keydown(selector: selector, key: key)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string(result)
        ]))
    }

    // MARK: browser.keyup

    private func keyup(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let selValue = params["selector"], case .string(let selector) = selValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: selector")
        }
        guard let keyValue = params["key"], case .string(let key) = keyValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: key")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.keyup(selector: selector, key: key)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string(result)
        ]))
    }

    // MARK: browser.get.html

    private func getHTML(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let selValue = params["selector"], case .string(let selector) = selValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: selector")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.getInnerHTML(selector: selector)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "html":       .string(result)
        ]))
    }

    // MARK: browser.get.value

    private func getValue(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let selValue = params["selector"], case .string(let selector) = selValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: selector")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.getInputValue(selector: selector)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "value":      .string(result)
        ]))
    }

    // MARK: browser.get.count

    private func getCount(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let selValue = params["selector"], case .string(let selector) = selValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: selector")
        }
        let controller = try resolveBrowserController(params: params)
        let count = try await controller.countElements(selector: selector)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "count":      .int(count)
        ]))
    }

    // MARK: browser.get.box

    private func getBox(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let selValue = params["selector"], case .string(let selector) = selValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: selector")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.getBoundingBox(selector: selector)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "box":        .string(result)
        ]))
    }

    // MARK: browser.get.styles

    private func getStyles(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let selValue = params["selector"], case .string(let selector) = selValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: selector")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.getComputedStyles(selector: selector)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "styles":     .string(result)
        ]))
    }

    // MARK: browser.is.visible

    private func isVisible(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let selValue = params["selector"], case .string(let selector) = selValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: selector")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.isVisible(selector: selector)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "visible":    .bool(result)
        ]))
    }

    // MARK: browser.is.enabled

    private func isEnabled(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let selValue = params["selector"], case .string(let selector) = selValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: selector")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.isEnabled(selector: selector)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "enabled":    .bool(result)
        ]))
    }

    // MARK: browser.is.checked

    private func isChecked(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let selValue = params["selector"], case .string(let selector) = selValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: selector")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.isChecked(selector: selector)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "checked":    .bool(result)
        ]))
    }

    // MARK: browser.find.role

    private func findRole(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let roleValue = params["role"], case .string(let role) = roleValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: role")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.findByRole(role)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string(result)
        ]))
    }

    // MARK: browser.find.text

    private func findByText(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let textValue = params["text"], case .string(let text) = textValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: text")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.findByText(text)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string(result)
        ]))
    }

    // MARK: browser.find.label

    private func findByLabel(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let textValue = params["text"], case .string(let text) = textValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: text")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.findByLabel(text)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string(result)
        ]))
    }

    // MARK: browser.find.placeholder

    private func findByPlaceholder(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let textValue = params["text"], case .string(let text) = textValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: text")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.findByPlaceholder(text)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string(result)
        ]))
    }

    // MARK: browser.find.alt

    private func findByAlt(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let textValue = params["text"], case .string(let text) = textValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: text")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.findByAlt(text)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string(result)
        ]))
    }

    // MARK: browser.find.title

    private func findByTitle(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let textValue = params["text"], case .string(let text) = textValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: text")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.findByTitle(text)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string(result)
        ]))
    }

    // MARK: browser.find.testid

    private func findByTestId(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let idValue = params["testid"], case .string(let testId) = idValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: testid")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.findByTestId(testId)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string(result)
        ]))
    }

    // MARK: browser.find.first

    private func findFirst(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let selValue = params["selector"], case .string(let selector) = selValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: selector")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.findFirst(selector: selector)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string(result)
        ]))
    }

    // MARK: browser.find.last

    private func findLast(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let selValue = params["selector"], case .string(let selector) = selValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: selector")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.findLast(selector: selector)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string(result)
        ]))
    }

    // MARK: browser.find.nth

    private func findNth(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let selValue = params["selector"], case .string(let selector) = selValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: selector")
        }
        let index: Int
        switch params["index"] {
        case .some(.int(let n)):    index = n
        case .some(.double(let n)): index = Int(n)
        default: throw JSONRPCError(code: -32602, message: "Missing required param: index")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.findNth(selector: selector, index: index)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string(result)
        ]))
    }

    // MARK: browser.dialog.accept

    private func dialogAccept(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        let text: String?
        if let v = params["text"], case .string(let s) = v { text = s } else { text = nil }
        let controller = try resolveBrowserController(params: params)
        try await controller.acceptDialog(text: text)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string("ok")
        ]))
    }

    // MARK: browser.dialog.dismiss

    private func dialogDismiss(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let controller = try resolveBrowserController(params: req.params?.object ?? [:])
        try await controller.dismissDialog(accept: false, text: nil)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string("ok")
        ]))
    }

    // MARK: browser.cookies.clear

    private func cookiesClear(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let controller = try resolveBrowserController(params: req.params?.object ?? [:])
        try await controller.clearAllCookies()
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string("ok")
        ]))
    }

    // MARK: browser.tab.new / list / switch / close
    // Tab management operates on the BrowserRegistry — creates/lists surface IDs.

    private func tabNew(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        let url: String
        if let v = params["url"], case .string(let s) = v { url = s } else { url = "about:blank" }
        // Notify the UI layer to open a new browser pane via the panel manager.
        NotificationCenter.default.post(
            name: .browserTabNew,
            object: nil,
            userInfo: ["url": url]
        )
        return .success(id: req.id, result: .object([
            "result": .string("ok"),
            "url":    .string(url)
        ]))
    }

    private func tabList(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let controllers = BrowserRegistry.shared.allControllers()
        let entries: [JSONRPCValue] = controllers.map { c in
            .object([
                "surface_id": .string(c.paneID.uuidString),
                "url":        .string(c.currentURL),
                "title":      .string(c.currentTitle)
            ])
        }
        return .success(id: req.id, result: .object([
            "tabs": .array(entries)
        ]))
    }

    private func tabSwitch(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let sidValue = params["surface_id"], case .string(let sid) = sidValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: surface_id")
        }
        NotificationCenter.default.post(
            name: .browserTabSwitch,
            object: nil,
            userInfo: ["surface_id": sid]
        )
        return .success(id: req.id, result: .object([
            "result":     .string("ok"),
            "surface_id": .string(sid)
        ]))
    }

    private func tabClose(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let sidValue = params["surface_id"], case .string(let sid) = sidValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: surface_id")
        }
        NotificationCenter.default.post(
            name: .browserTabClose,
            object: nil,
            userInfo: ["surface_id": sid]
        )
        return .success(id: req.id, result: .object([
            "result":     .string("ok"),
            "surface_id": .string(sid)
        ]))
    }

    // MARK: browser.console.list

    private func consoleList(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
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

    // MARK: browser.errors.list

    private func errorsList(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let controller = try resolveBrowserController(params: req.params?.object ?? [:])
        let logs = try await controller.consoleLogs()
        let errors = logs.filter { $0.level == "error" }
        let entries: [JSONRPCValue] = errors.map { msg in
            .object([
                "level": .string(msg.level),
                "args":  .array(msg.args.map { .string($0) }),
                "ts":    .double(msg.timestamp)
            ])
        }
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "errors":     .array(entries)
        ]))
    }

    // MARK: browser.highlight

    private func highlight(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let selValue = params["selector"], case .string(let selector) = selValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: selector")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.highlight(selector: selector)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string(result)
        ]))
    }

    // MARK: browser.state.save

    private func stateSave(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let controller = try resolveBrowserController(params: req.params?.object ?? [:])
        let state = try await controller.savePageState()
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "state":      .string(state)
        ]))
    }

    // MARK: browser.state.load

    private func stateLoad(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let stateValue = params["state"], case .string(let state) = stateValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: state")
        }
        let controller = try resolveBrowserController(params: params)
        let result = try await controller.loadPageState(state)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string(result)
        ]))
    }

    // MARK: browser.network.requests

    private func networkRequests(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let controller = try resolveBrowserController(params: req.params?.object ?? [:])
        let result = try await controller.networkRequests()
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "requests":   .string(result)
        ]))
    }

    // MARK: - US-018 handlers

    // MARK: browser.snapshot

    private func snapshot(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let controller = try resolveBrowserController(params: req.params?.object ?? [:])
        let data = try await controller.takeScreenshot()
        let base64 = data.base64EncodedString()
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "data":       .string(base64),
            "encoding":   .string("base64"),
            "format":     .string("png"),
            "full_page":  .bool(true)
        ]))
    }

    // MARK: browser.geolocation.set

    private func geolocationSet(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        let lat: Double
        let lon: Double
        switch params["latitude"] {
        case .some(.double(let n)): lat = n
        case .some(.int(let n)):    lat = Double(n)
        default: throw JSONRPCError(code: -32602, message: "Missing required param: latitude")
        }
        switch params["longitude"] {
        case .some(.double(let n)): lon = n
        case .some(.int(let n)):    lon = Double(n)
        default: throw JSONRPCError(code: -32602, message: "Missing required param: longitude")
        }
        let accuracy: Double
        switch params["accuracy"] {
        case .some(.double(let n)): accuracy = n
        case .some(.int(let n)):    accuracy = Double(n)
        default: accuracy = 1.0
        }
        let controller = try resolveBrowserController(params: params)
        let js = """
        (function() {
          const pos = {
            coords: {
              latitude: \(lat),
              longitude: \(lon),
              accuracy: \(accuracy),
              altitude: null, altitudeAccuracy: null, heading: null, speed: null
            },
            timestamp: Date.now()
          };
          navigator.__namuGeolocationOverride = pos;
          const _getCurrentPosition = navigator.geolocation.getCurrentPosition.bind(navigator.geolocation);
          navigator.geolocation.getCurrentPosition = function(success, error, opts) {
            success(navigator.__namuGeolocationOverride);
          };
          navigator.geolocation.watchPosition = function(success, error, opts) {
            success(navigator.__namuGeolocationOverride);
            return 0;
          };
        })();
        """
        _ = try await controller.evaluateJS(js)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "latitude":   .double(lat),
            "longitude":  .double(lon),
            "accuracy":   .double(accuracy)
        ]))
    }

    // MARK: browser.offline.set

    private func offlineSet(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        let offline: Bool
        switch params["offline"] {
        case .some(.bool(let b)): offline = b
        default: throw JSONRPCError(code: -32602, message: "Missing required param: offline")
        }
        let controller = try resolveBrowserController(params: params)
        let js = offline ? """
        (function() {
          window.__namuOffline = true;
          const origFetch = window.__namuOrigFetch || window.fetch;
          window.__namuOrigFetch = origFetch;
          window.fetch = function() {
            return Promise.reject(new TypeError('Network request failed (namu offline mode)'));
          };
          window.XMLHttpRequest = (function(OrigXHR) {
            function FakeXHR() {}
            FakeXHR.prototype.open = function() {};
            FakeXHR.prototype.send = function() {
              if (this.onerror) this.onerror(new Error('Network request failed (namu offline mode)'));
            };
            return FakeXHR;
          })(window.XMLHttpRequest);
        })();
        """ : """
        (function() {
          if (window.__namuOrigFetch) { window.fetch = window.__namuOrigFetch; delete window.__namuOrigFetch; }
          delete window.__namuOffline;
        })();
        """
        _ = try await controller.evaluateJS(js)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "offline":    .bool(offline)
        ]))
    }

    // MARK: browser.trace.start

    private func traceStart(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let controller = try resolveBrowserController(params: req.params?.object ?? [:])
        try await controller.startNetworkTrace()
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "tracing":    .bool(true)
        ]))
    }

    // MARK: browser.trace.stop

    private func traceStop(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let controller = try resolveBrowserController(params: req.params?.object ?? [:])
        let traceJSON = try await controller.stopNetworkTrace()
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "trace":      .string(traceJSON)
        ]))
    }

    // MARK: browser.input_mouse

    private func inputMouse(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        let x: Double
        let y: Double
        switch params["x"] {
        case .some(.double(let n)): x = n
        case .some(.int(let n)):    x = Double(n)
        default: throw JSONRPCError(code: -32602, message: "Missing required param: x")
        }
        switch params["y"] {
        case .some(.double(let n)): y = n
        case .some(.int(let n)):    y = Double(n)
        default: throw JSONRPCError(code: -32602, message: "Missing required param: y")
        }
        let action: String
        if case .some(.string(let a)) = params["action"] { action = a } else { action = "click" }
        let controller = try resolveBrowserController(params: params)
        let js: String
        switch action {
        case "move":
            js = "document.elementFromPoint(\(x), \(y))?.dispatchEvent(new MouseEvent('mousemove', {clientX:\(x),clientY:\(y),bubbles:true}));"
        case "down":
            js = "document.elementFromPoint(\(x), \(y))?.dispatchEvent(new MouseEvent('mousedown', {clientX:\(x),clientY:\(y),bubbles:true}));"
        case "up":
            js = "document.elementFromPoint(\(x), \(y))?.dispatchEvent(new MouseEvent('mouseup', {clientX:\(x),clientY:\(y),bubbles:true}));"
        default:
            js = "document.elementFromPoint(\(x), \(y))?.dispatchEvent(new MouseEvent('click', {clientX:\(x),clientY:\(y),bubbles:true}));"
        }
        _ = try await controller.evaluateJS(js)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string("ok")
        ]))
    }

    // MARK: browser.input_keyboard

    private func inputKeyboard(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        guard let keyValue = params["key"], case .string(let key) = keyValue else {
            throw JSONRPCError(code: -32602, message: "Missing required param: key")
        }
        let action: String
        if case .some(.string(let a)) = params["action"] { action = a } else { action = "press" }
        let controller = try resolveBrowserController(params: params)
        let eventType: String
        switch action {
        case "down": eventType = "keydown"
        case "up":   eventType = "keyup"
        default:     eventType = "keypress"
        }
        let escapedKey = key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let js = "document.activeElement?.dispatchEvent(new KeyboardEvent('\(eventType)', {key:'\(escapedKey)',bubbles:true}));"
        _ = try await controller.evaluateJS(js)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string("ok")
        ]))
    }

    // MARK: browser.input_touch

    private func inputTouch(_ req: JSONRPCRequest) async throws -> JSONRPCResponse {
        let params = req.params?.object ?? [:]
        let x: Double
        let y: Double
        switch params["x"] {
        case .some(.double(let n)): x = n
        case .some(.int(let n)):    x = Double(n)
        default: throw JSONRPCError(code: -32602, message: "Missing required param: x")
        }
        switch params["y"] {
        case .some(.double(let n)): y = n
        case .some(.int(let n)):    y = Double(n)
        default: throw JSONRPCError(code: -32602, message: "Missing required param: y")
        }
        let action: String
        if case .some(.string(let a)) = params["action"] { action = a } else { action = "tap" }
        let controller = try resolveBrowserController(params: params)
        let eventType: String
        switch action {
        case "start":  eventType = "touchstart"
        case "end":    eventType = "touchend"
        case "move":   eventType = "touchmove"
        default:       eventType = "touchstart"
        }
        let js = """
        (function() {
          var el = document.elementFromPoint(\(x), \(y));
          if (!el) return;
          var touch = new Touch({identifier: Date.now(), target: el, clientX: \(x), clientY: \(y)});
          el.dispatchEvent(new TouchEvent('\(eventType)', {touches:[touch],changedTouches:[touch],bubbles:true}));
        })();
        """
        _ = try await controller.evaluateJS(js)
        return .success(id: req.id, result: .object([
            "surface_id": .string(controller.paneID.uuidString),
            "result":     .string("ok")
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
