import XCTest
@testable import Namu

// MARK: - Test Delegate

private final class MockAlertDelegate: AlertEngineDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _firedAlerts: [FiredAlert] = []

    var firedAlerts: [FiredAlert] {
        lock.withLock { _firedAlerts }
    }

    func alertEngine(_ engine: AlertEngine, didFire alert: FiredAlert) {
        lock.withLock { _firedAlerts.append(alert) }
    }
}

// MARK: - Integration Tests

final class AlertEngineIntegrationTests: XCTestCase {

    private var eventBus: EventBus!
    private var engine: AlertEngine!
    private var delegate: MockAlertDelegate!

    override func setUp() {
        super.setUp()
        eventBus = EventBus()
        engine = AlertEngine(eventBus: eventBus)
        delegate = MockAlertDelegate()
        engine.delegate = delegate
    }

    override func tearDown() {
        engine.stop()
        engine = nil
        eventBus = nil
        delegate = nil
        super.tearDown()
    }

    // MARK: - Configuration: Add Rules and Verify

    func testAddRuleAndVerify() {
        let rule = AlertRule(
            name: "Non-zero exit",
            trigger: .processExit(exitCode: 1)
        )

        engine.addRule(rule)

        let rules = engine.rules
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules.first?.id, rule.id)
        XCTAssertEqual(rules.first?.name, "Non-zero exit")
        XCTAssertTrue(rules.first?.isEnabled ?? false)
    }

    func testAddMultipleRulesAndVerify() {
        let exitRule = AlertRule(name: "Exit watcher", trigger: .processExit(exitCode: nil))
        let outputRule = AlertRule(name: "Error detector", trigger: .outputMatch(pattern: "FATAL", caseSensitive: true))
        let portRule = AlertRule(name: "Port monitor", trigger: .portChange(ports: [3000, 8080]))
        let idleRule = AlertRule(name: "Idle alert", trigger: .shellIdle(seconds: 300))

        engine.addRule(exitRule)
        engine.addRule(outputRule)
        engine.addRule(portRule)
        engine.addRule(idleRule)

        let rules = engine.rules
        XCTAssertEqual(rules.count, 4)
        XCTAssertEqual(rules.map(\.name), ["Exit watcher", "Error detector", "Port monitor", "Idle alert"])
    }

    func testRemoveRule() {
        let rule1 = AlertRule(name: "Rule A", trigger: .processExit(exitCode: nil))
        let rule2 = AlertRule(name: "Rule B", trigger: .shellIdle(seconds: 60))

        engine.addRule(rule1)
        engine.addRule(rule2)
        XCTAssertEqual(engine.rules.count, 2)

        engine.removeRule(id: rule1.id)

        XCTAssertEqual(engine.rules.count, 1)
        XCTAssertEqual(engine.rules.first?.id, rule2.id)
    }

    func testUpdateRule() {
        var rule = AlertRule(name: "Original", trigger: .processExit(exitCode: 1))
        engine.addRule(rule)

        rule.name = "Updated"
        rule.isEnabled = false
        engine.updateRule(rule)

        let stored = engine.rules.first
        XCTAssertEqual(stored?.name, "Updated")
        XCTAssertEqual(stored?.isEnabled, false)
    }

    func testSetRulesReplacesAll() {
        engine.addRule(AlertRule(name: "Old", trigger: .processExit(exitCode: nil)))
        XCTAssertEqual(engine.rules.count, 1)

        let newRules = [
            AlertRule(name: "New A", trigger: .shellIdle(seconds: 10)),
            AlertRule(name: "New B", trigger: .portChange(ports: [4000])),
        ]
        engine.setRules(newRules)

        XCTAssertEqual(engine.rules.count, 2)
        XCTAssertEqual(engine.rules.map(\.name), ["New A", "New B"])
    }

    // MARK: - Full Flow: Configure → Start → Fire Event → Verify Alert

    func testProcessExitTriggerFires() {
        let rule = AlertRule(name: "Crash detector", trigger: .processExit(exitCode: 1))
        engine.addRule(rule)
        engine.start()

        eventBus.publish(event: .processExit, params: ["exit_code": .int(1)])

        let expectation = expectation(description: "Alert fires")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2)

        let alerts = delegate.firedAlerts
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.rule.id, rule.id)
        XCTAssertEqual(alerts.first?.event, .processExit)
    }

    func testProcessExitWildcardMatchesAnyCode() {
        let rule = AlertRule(name: "Any exit", trigger: .processExit(exitCode: nil))
        engine.addRule(rule)
        engine.start()

        eventBus.publish(event: .processExit, params: ["exit_code": .int(137)])

        let expectation = expectation(description: "Wildcard alert fires")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2)

        XCTAssertEqual(delegate.firedAlerts.count, 1)
    }

    func testProcessExitWrongCodeDoesNotFire() {
        let rule = AlertRule(name: "Only code 1", trigger: .processExit(exitCode: 1))
        engine.addRule(rule)
        engine.start()

        eventBus.publish(event: .processExit, params: ["exit_code": .int(0)])

        let expectation = expectation(description: "No alert expected")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2)

        XCTAssertTrue(delegate.firedAlerts.isEmpty)
    }

    func testOutputMatchTriggerFires() {
        let rule = AlertRule(
            name: "Error watcher",
            trigger: .outputMatch(pattern: "error", caseSensitive: false)
        )
        engine.addRule(rule)
        engine.start()

        eventBus.publish(event: .outputMatch, params: ["text": .string("Build ERROR: compilation failed")])

        let expectation = expectation(description: "Output match fires")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2)

        XCTAssertEqual(delegate.firedAlerts.count, 1)
        XCTAssertEqual(delegate.firedAlerts.first?.rule.name, "Error watcher")
    }

    func testOutputMatchCaseSensitiveDoesNotFireOnWrongCase() {
        let rule = AlertRule(
            name: "Exact match",
            trigger: .outputMatch(pattern: "FATAL", caseSensitive: true)
        )
        engine.addRule(rule)
        engine.start()

        eventBus.publish(event: .outputMatch, params: ["text": .string("fatal: something happened")])

        let expectation = expectation(description: "No case-sensitive match")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2)

        XCTAssertTrue(delegate.firedAlerts.isEmpty)
    }

    func testPortChangeTriggerFires() {
        let rule = AlertRule(name: "Port 3000", trigger: .portChange(ports: [3000, 8080]))
        engine.addRule(rule)
        engine.start()

        eventBus.publish(event: .portChange, params: ["port": .int(3000)])

        let expectation = expectation(description: "Port change fires")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2)

        XCTAssertEqual(delegate.firedAlerts.count, 1)
    }

    func testPortChangeUnwatchedPortDoesNotFire() {
        let rule = AlertRule(name: "Port 3000", trigger: .portChange(ports: [3000]))
        engine.addRule(rule)
        engine.start()

        eventBus.publish(event: .portChange, params: ["port": .int(5432)])

        let expectation = expectation(description: "No alert for unwatched port")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2)

        XCTAssertTrue(delegate.firedAlerts.isEmpty)
    }

    func testShellIdleTriggerFires() {
        let rule = AlertRule(name: "Idle 5min", trigger: .shellIdle(seconds: 300))
        engine.addRule(rule)
        engine.start()

        eventBus.publish(event: .shellIdle, params: ["idle_seconds": .double(350.5)])

        let expectation = expectation(description: "Shell idle fires")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2)

        XCTAssertEqual(delegate.firedAlerts.count, 1)
    }

    func testShellIdleBelowThresholdDoesNotFire() {
        let rule = AlertRule(name: "Idle 5min", trigger: .shellIdle(seconds: 300))
        engine.addRule(rule)
        engine.start()

        eventBus.publish(event: .shellIdle, params: ["idle_seconds": .double(100.5)])

        let expectation = expectation(description: "No alert below threshold")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2)

        XCTAssertTrue(delegate.firedAlerts.isEmpty)
    }

    // MARK: - Disabled Rules

    func testDisabledRuleDoesNotFire() {
        let rule = AlertRule(
            name: "Disabled exit",
            isEnabled: false,
            trigger: .processExit(exitCode: nil)
        )
        engine.addRule(rule)
        engine.start()

        eventBus.publish(event: .processExit, params: ["exit_code": .int(1)])

        let expectation = expectation(description: "Disabled rule skipped")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2)

        XCTAssertTrue(delegate.firedAlerts.isEmpty)
    }

    // MARK: - Multiple Rules Fire on Same Event

    func testMultipleRulesCanFireOnSameEvent() {
        let rule1 = AlertRule(name: "Any exit", trigger: .processExit(exitCode: nil))
        let rule2 = AlertRule(name: "Exit code 1", trigger: .processExit(exitCode: 1))
        engine.addRule(rule1)
        engine.addRule(rule2)
        engine.start()

        eventBus.publish(event: .processExit, params: ["exit_code": .int(1)])

        let expectation = expectation(description: "Both rules fire")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2)

        XCTAssertEqual(delegate.firedAlerts.count, 2)
        let names = Set(delegate.firedAlerts.map(\.rule.name))
        XCTAssertEqual(names, ["Any exit", "Exit code 1"])
    }

    // MARK: - Stop Prevents Further Alerts

    func testStopPreventsAlerts() {
        let rule = AlertRule(name: "Exit", trigger: .processExit(exitCode: nil))
        engine.addRule(rule)
        engine.start()
        engine.stop()

        eventBus.publish(event: .processExit, params: ["exit_code": .int(1)])

        let expectation = expectation(description: "No alerts after stop")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        waitForExpectations(timeout: 2)

        XCTAssertTrue(delegate.firedAlerts.isEmpty)
    }

    // MARK: - End-to-End: Configure, Fire, Update, Fire Again

    func testEndToEndConfigureFireUpdateFire() {
        // Step 1: Configure a rule
        var rule = AlertRule(name: "Error watcher", trigger: .outputMatch(pattern: "error", caseSensitive: false))
        engine.addRule(rule)
        engine.start()

        // Step 2: Publish matching event — should fire
        eventBus.publish(event: .outputMatch, params: ["text": .string("error: something broke")])

        let firstFire = expectation(description: "First alert fires")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            firstFire.fulfill()
        }
        waitForExpectations(timeout: 2)
        XCTAssertEqual(delegate.firedAlerts.count, 1)

        // Step 3: Update the rule to be more specific (case-sensitive "FATAL")
        rule.name = "Fatal only"
        rule.trigger = .outputMatch(pattern: "FATAL", caseSensitive: true)
        engine.updateRule(rule)

        // Step 4: Old pattern should no longer match
        eventBus.publish(event: .outputMatch, params: ["text": .string("error: another failure")])

        let noFire = expectation(description: "Updated rule skips old pattern")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            noFire.fulfill()
        }
        waitForExpectations(timeout: 2)
        XCTAssertEqual(delegate.firedAlerts.count, 1) // still 1

        // Step 5: New pattern should match
        eventBus.publish(event: .outputMatch, params: ["text": .string("FATAL: disk full")])

        let secondFire = expectation(description: "Updated rule fires on new pattern")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            secondFire.fulfill()
        }
        waitForExpectations(timeout: 2)
        XCTAssertEqual(delegate.firedAlerts.count, 2)
        XCTAssertEqual(delegate.firedAlerts.last?.rule.name, "Fatal only")
    }

    // MARK: - Core Happy Path

    /// The primary integration flow: configure rules → persist → reload → start →
    /// publish one event per trigger type → verify every matching rule fires with
    /// correct data and non-matching rules stay silent.
    func testCoreHappyPath() {
        // 1. Configure automation rules — one per trigger type
        let exitRule = AlertRule(name: "Crash alert", trigger: .processExit(exitCode: 1))
        let outputRule = AlertRule(name: "Error output", trigger: .outputMatch(pattern: "error", caseSensitive: false))
        let portRule = AlertRule(name: "Dev server", trigger: .portChange(ports: [3000]))
        let idleRule = AlertRule(name: "Gone idle", trigger: .shellIdle(seconds: 60))
        let disabledRule = AlertRule(name: "Disabled", isEnabled: false, trigger: .processExit(exitCode: nil))

        let allRules = [exitRule, outputRule, portRule, idleRule, disabledRule]
        engine.setRules(allRules)

        // 2. Persist and reload — verify rules survive the round-trip
        engine.saveRules()

        let engine2 = AlertEngine(eventBus: eventBus)
        engine2.loadRules()
        let loaded = engine2.rules
        XCTAssertEqual(loaded.count, allRules.count)
        for (original, restored) in zip(allRules, loaded) {
            XCTAssertEqual(original.id, restored.id)
            XCTAssertEqual(original.name, restored.name)
            XCTAssertEqual(original.isEnabled, restored.isEnabled)
        }

        // Continue with the reloaded engine so we're testing the persisted state
        let reloadedDelegate = MockAlertDelegate()
        engine2.delegate = reloadedDelegate
        engine2.start()

        // 3. Fire a process exit event (code 1) — exitRule should match, disabledRule should not
        eventBus.publish(event: .processExit, params: ["exit_code": .int(1)])

        let exitExpectation = expectation(description: "Process exit alert")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exitExpectation.fulfill() }
        waitForExpectations(timeout: 2)

        let exitAlerts = reloadedDelegate.firedAlerts.filter { $0.event == .processExit }
        XCTAssertEqual(exitAlerts.count, 1, "Only the enabled exit rule should fire")
        XCTAssertEqual(exitAlerts.first?.rule.id, exitRule.id)

        // 4. Fire an output match event
        eventBus.publish(event: .outputMatch, params: ["text": .string("Build ERROR: link failed")])

        let outputExpectation = expectation(description: "Output match alert")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { outputExpectation.fulfill() }
        waitForExpectations(timeout: 2)

        let outputAlerts = reloadedDelegate.firedAlerts.filter { $0.event == .outputMatch }
        XCTAssertEqual(outputAlerts.count, 1)
        XCTAssertEqual(outputAlerts.first?.rule.id, outputRule.id)

        // 5. Fire a port change event
        eventBus.publish(event: .portChange, params: ["port": .int(3000)])

        let portExpectation = expectation(description: "Port change alert")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { portExpectation.fulfill() }
        waitForExpectations(timeout: 2)

        let portAlerts = reloadedDelegate.firedAlerts.filter { $0.event == .portChange }
        XCTAssertEqual(portAlerts.count, 1)
        XCTAssertEqual(portAlerts.first?.rule.id, portRule.id)

        // 6. Fire a shell idle event
        eventBus.publish(event: .shellIdle, params: ["idle_seconds": .double(120.5)])

        let idleExpectation = expectation(description: "Shell idle alert")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { idleExpectation.fulfill() }
        waitForExpectations(timeout: 2)

        let idleAlerts = reloadedDelegate.firedAlerts.filter { $0.event == .shellIdle }
        XCTAssertEqual(idleAlerts.count, 1)
        XCTAssertEqual(idleAlerts.first?.rule.id, idleRule.id)

        // 7. Verify total: exactly 4 alerts (disabled rule never fired)
        XCTAssertEqual(reloadedDelegate.firedAlerts.count, 4)
        let firedIDs = Set(reloadedDelegate.firedAlerts.map(\.rule.id))
        XCTAssertFalse(firedIDs.contains(disabledRule.id), "Disabled rule must not fire")

        // 8. Verify each alert carries the correct event type
        for alert in reloadedDelegate.firedAlerts {
            switch alert.rule.trigger {
            case .processExit:  XCTAssertEqual(alert.event, .processExit)
            case .outputMatch:  XCTAssertEqual(alert.event, .outputMatch)
            case .portChange:   XCTAssertEqual(alert.event, .portChange)
            case .shellIdle:    XCTAssertEqual(alert.event, .shellIdle)
            }
        }

        engine2.stop()
    }

    // MARK: - Codable Round-Trip (Persistence)

    func testAlertRuleCodableRoundTrip() throws {
        let rules: [AlertRule] = [
            AlertRule(name: "Exit", trigger: .processExit(exitCode: 1)),
            AlertRule(name: "Output", trigger: .outputMatch(pattern: "warn", caseSensitive: false)),
            AlertRule(name: "Port", trigger: .portChange(ports: [3000])),
            AlertRule(name: "Idle", trigger: .shellIdle(seconds: 120)),
        ]

        let data = try JSONEncoder().encode(rules)
        let decoded = try JSONDecoder().decode([AlertRule].self, from: data)

        XCTAssertEqual(decoded.count, rules.count)
        for (original, restored) in zip(rules, decoded) {
            XCTAssertEqual(original.id, restored.id)
            XCTAssertEqual(original.name, restored.name)
            XCTAssertEqual(original.isEnabled, restored.isEnabled)
        }
    }

    // MARK: - Default Rules

    func testDefaultRulesAreValid() {
        let defaults = AlertEngine.defaultRules
        XCTAssertEqual(defaults.count, 4)
        XCTAssertTrue(defaults.allSatisfy(\.isEnabled))

        engine.setRules(defaults)
        XCTAssertEqual(engine.rules.count, 4)
    }

    // MARK: - EventBus Subscription Lifecycle

    func testEventBusSubscriptionCleanup() {
        XCTAssertEqual(eventBus.subscriberCount, 0)

        engine.start()
        XCTAssertEqual(eventBus.subscriberCount, 1)

        engine.stop()
        XCTAssertEqual(eventBus.subscriberCount, 0)

        // Double stop is safe
        engine.stop()
        XCTAssertEqual(eventBus.subscriberCount, 0)
    }
}
