import XCTest
@testable import TrustoConsent

final class KeyAndRulesTests: XCTestCase {
    func testPublishableKeyFormat() {
        XCTAssertTrue(TrustoConsent.isValidPublishableKey(validKey))
        XCTAssertTrue(TrustoConsent.isValidPublishableKey("trusto_pk_live_" + String(repeating: "a_-9", count: 8)))
        XCTAssertFalse(TrustoConsent.isValidPublishableKey("trusto_sk_live_" + String(repeating: "A", count: 43)), "chave secreta nunca")
        XCTAssertFalse(TrustoConsent.isValidPublishableKey("trusto_pk_prod_" + String(repeating: "A", count: 32)))
        XCTAssertFalse(TrustoConsent.isValidPublishableKey("trusto_pk_test_" + String(repeating: "A", count: 31)))
        XCTAssertFalse(TrustoConsent.isValidPublishableKey(validKey + " "))
        XCTAssertThrowsError(try TrustoConsent(publishableKey: "x", appIdentifier: bundleId)) {
            XCTAssertEqual($0 as? TrustoConsentError, .invalidPublishableKey)
        }
        XCTAssertThrowsError(try TrustoConsent(publishableKey: validKey, appIdentifier: nil)) {
            XCTAssertEqual($0 as? TrustoConsentError, .missingAppIdentifier)
        }
    }

    private func config() throws -> ConsentConfig {
        try JSONDecoder().decode(ConsentConfig.self, from: JSONSerialization.data(withJSONObject: configJSON()))
    }

    func testDecisionRulesMatchTheCollector() throws {
        let config = try config()
        let all = try DecisionRules.build(.acceptAll, config: config)
        XCTAssertEqual(all.0, .acceptAll)
        XCTAssertEqual(all.1, ["necessary": true, "analytics": true, "marketing": true])

        let none = try DecisionRules.build(.rejectAll, config: config)
        XCTAssertEqual(none.0, .rejectAll)
        XCTAssertEqual(none.1, ["necessary": true, "analytics": false, "marketing": false])

        let revoke = try DecisionRules.build(.revoke, config: config)
        XCTAssertEqual(revoke.0, .revoke)
        XCTAssertEqual(revoke.1, none.1)

        let some = try DecisionRules.build(.custom(["analytics": true]), config: config)
        XCTAssertEqual(some.0, .partial)
        XCTAssertEqual(some.1, ["necessary": true, "analytics": true, "marketing": false], "não informada fica recusada")

        XCTAssertEqual(try DecisionRules.build(.custom(["analytics": true, "marketing": true]), config: config).0, .acceptAll)
        XCTAssertEqual(try DecisionRules.build(.custom([:]), config: config).0, .rejectAll)
        XCTAssertThrowsError(try DecisionRules.build(.custom(["outra": true]), config: config)) {
            XCTAssertEqual($0 as? TrustoConsentError, .unknownCategory("outra"))
        }
        XCTAssertThrowsError(try DecisionRules.build(.custom(["necessary": false]), config: config)) {
            XCTAssertEqual($0 as? TrustoConsentError, .requiredCategoryRefused("necessary"))
        }
        for (action, categories) in [all, none, revoke, some] {
            XCTAssertTrue(DecisionRules.isValid(action: action, categories: categories, config: config))
        }
        XCTAssertFalse(DecisionRules.isValid(action: .partial, categories: all.1, config: config))
        XCTAssertFalse(DecisionRules.isValid(action: .acceptAll, categories: ["necessary": true], config: config))
    }

    func testDeviceSanitization() {
        XCTAssertEqual(DeviceInfo.sanitize("iOS 18.1", max: 40), "iOS 18.1")
        XCTAssertEqual(DeviceInfo.sanitize("iPhone15,2", max: 60), "iPhone15,2")
        XCTAssertEqual(DeviceInfo.sanitize("<script>x</script>", max: 40), "script x /script")
        XCTAssertEqual(DeviceInfo.sanitize("a\u{0}b\nc", max: 40), "a b c")
        XCTAssertEqual(DeviceInfo.sanitize(String(repeating: "x", count: 100), max: 40)?.count, 40)
        XCTAssertNil(DeviceInfo.sanitize("<>", max: 40))
        XCTAssertEqual(DeviceInfo.make(os: "@@@", device: "%%").os, "iOS")
        XCTAssertNil(DeviceInfo.make(os: "iOS 18", device: "%%").device)
        let current = DeviceInfo.current()
        let allowed = try! NSRegularExpression(pattern: "^[\\p{L}\\p{N} ._()\\-/,+]+$")
        XCTAssertNotNil(allowed.firstMatch(in: current.os, range: NSRange(current.os.startIndex..., in: current.os)))
        XCTAssertLessThanOrEqual(current.os.count, 40)
    }
}

final class FlowTests: XCTestCase {
    func testConfigRequestShapeAndCache() async throws {
        let h = Harness()
        h.transport.on("/v1/app/config", .json(200, configJSON()))
        let consent = try h.make()
        let config = try await consent.loadConfig()
        XCTAssertEqual(config.version, 2)
        XCTAssertEqual(config.categories.map(\.key), ["necessary", "analytics", "marketing"])

        let request = try XCTUnwrap(h.transport.requests(to: "/v1/app/config").first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(validKey)")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(Set(query.map { "\($0.name)=\($0.value!)" }), ["platform=ios", "app=\(bundleId)"])

        _ = try await consent.loadConfig()
        XCTAssertEqual(h.transport.requests(to: "/v1/app/config").count, 1, "60 s de cache")
        h.clock.advance(61)
        _ = try await consent.loadConfig()
        XCTAssertEqual(h.transport.requests(to: "/v1/app/config").count, 2)
    }

    func testOfflineFallsBackToTheLastConfigOnDisk() async throws {
        let h = Harness()
        h.transport.on("/v1/app/config", .json(200, configJSON(version: 4)))
        _ = try await h.make().loadConfig()

        h.clock.advance(3_600)
        h.transport.on("/v1/app/config", .offline)
        let reopened = try h.make()
        let config = try await reopened.loadConfig()
        XCTAssertEqual(config.version, 4, "sem rede, o último banner guardado")

        let empty = Harness()
        empty.transport.on("/v1/app/config", .json(503, ["error": "unavailable"]))
        do {
            _ = try await empty.make().loadConfig()
            XCTFail("sem banner guardado, o erro aparece")
        } catch {
            XCTAssertEqual(error as? TrustoConsentError, .unavailable)
        }
    }

    func testConfigErrorsAreTyped() async throws {
        for (status, expected) in [(401, TrustoConsentError.invalidAppKey), (403, .appMismatch), (404, .consentNotEnabled), (429, .rateLimited)] {
            let h = Harness()
            h.transport.on("/v1/app/config", .json(status, ["error": "x"]))
            do {
                _ = try await h.make().loadConfig()
                XCTFail("\(status) devia falhar")
            } catch {
                XCTAssertEqual(error as? TrustoConsentError, expected)
            }
        }
    }

    func testRecordBodyIsExactlyTheContract() async throws {
        let h = Harness()
        h.transport.on("/v1/app/config", .json(200, configJSON()))
        h.transport.on("/v1/app/records", .json(201, receiptJSON))
        let consent = try h.make()
        let decision = try await consent.save(categories: ["analytics": true])

        let request = try XCTUnwrap(h.transport.requests(to: "/v1/app/records").first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(validKey)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["visitorId", "action", "categories", "configVersion", "app"])
        XCTAssertEqual(body["action"] as? String, "partial")
        XCTAssertEqual(body["configVersion"] as? Int, 2)
        XCTAssertEqual(body["categories"] as? [String: Bool], ["necessary": true, "analytics": true, "marketing": false])
        let visitor = try XCTUnwrap(body["visitorId"] as? String)
        XCTAssertNotNil(UUID(uuidString: visitor))
        XCTAssertEqual(visitor, visitor.lowercased())
        let app = try XCTUnwrap(body["app"] as? [String: Any])
        XCTAssertTrue(Set(app.keys).isSubset(of: ["platform", "identifier", "sdkVersion", "os", "device"]))
        XCTAssertEqual(app["platform"] as? String, "ios")
        XCTAssertEqual(app["identifier"] as? String, bundleId)
        XCTAssertEqual(app["sdkVersion"] as? String, TrustoConsent.sdkVersion)
        XCTAssertNotNil(app["os"] as? String)

        XCTAssertEqual(decision.consentId, "c0ffee00-0000-4000-8000-000000000000")
        XCTAssertTrue(decision.isRecorded)
        XCTAssertEqual(consent.pendingCount, 0)
        XCTAssertFalse(consent.needsConsent)
        XCTAssertTrue(consent.isGranted("analytics"))
        XCTAssertFalse(consent.isGranted("marketing"))
    }

    func testVisitorIdIsStableAndRandom() async throws {
        let h = Harness()
        let first = try h.make().visitorId()
        XCTAssertEqual(try h.make().visitorId(), first, "o mesmo identificador no mesmo aparelho")
        XCTAssertEqual(h.secure.read("visitorId"), first)
        XCTAssertNotEqual(try Harness().make().visitorId(), first)
    }

    func testOfflineDecisionIsAppliedQueuedAndSentLater() async throws {
        let h = Harness()
        h.transport.on("/v1/app/config", .json(200, configJSON()))
        h.transport.on("/v1/app/records", .offline)
        let consent = try h.make()
        let decision = try await consent.acceptAll()
        XCTAssertFalse(decision.isRecorded)
        XCTAssertTrue(consent.isGranted("marketing"), "vale no aparelho antes de chegar ao coletor")
        XCTAssertEqual(consent.pendingCount, 1)

        // Antes do prazo de reenvio, nada sai.
        await consent.flush()
        XCTAssertEqual(h.transport.requests(to: "/v1/app/records").count, 1)

        // O app é reaberto: a decisão e a fila voltam do disco.
        h.transport.on("/v1/app/records", .json(201, receiptJSON))
        h.clock.advance(6)
        let reopened = try h.make()
        XCTAssertEqual(reopened.decision?.action, .acceptAll)
        XCTAssertEqual(reopened.pendingCount, 1)
        await reopened.flush()
        XCTAssertEqual(reopened.pendingCount, 0)
        XCTAssertTrue(reopened.decision?.isRecorded == true)
        XCTAssertEqual(try h.make().decision?.consentId, "c0ffee00-0000-4000-8000-000000000000")
    }

    func testRetryBacksOffExponentiallyUpToAnHour() async throws {
        let h = Harness()
        h.transport.on("/v1/app/config", .json(200, configJSON()))
        h.transport.on("/v1/app/records", .json(503, ["error": "unavailable"]))
        let consent = try h.make()
        _ = try await consent.rejectAll()
        var sent = 1
        var expected: TimeInterval = 5
        for _ in 0..<14 {
            h.clock.advance(expected - 1)
            await consent.flush()
            XCTAssertEqual(h.transport.requests(to: "/v1/app/records").count, sent, "antes do prazo")
            h.clock.advance(1)
            await consent.flush()
            sent += 1
            XCTAssertEqual(h.transport.requests(to: "/v1/app/records").count, sent)
            expected = min(expected * 2, 3_600)
        }
        XCTAssertEqual(expected, 3_600)
        XCTAssertEqual(consent.pendingCount, 1, "429 e 5xx ficam na fila")
    }

    func testTerminalAndDiscardedResponsesLeaveTheQueue() async throws {
        for status in [400, 401, 403, 404, 413, 202] {
            let h = Harness()
            h.transport.on("/v1/app/config", .json(200, configJSON()))
            h.transport.on("/v1/app/records", status == 202 ? .json(202, ["discarded": true]) : .json(status, ["error": "x"]))
            let consent = try h.make()
            let decision = try await consent.acceptAll()
            XCTAssertEqual(consent.pendingCount, 0, "\(status) sai da fila")
            XCTAssertFalse(decision.isRecorded)
        }
    }

    func testOutdatedBannerAsksAgain() async throws {
        let h = Harness()
        h.transport.on("/v1/app/config", .json(200, configJSON(version: 2)), .json(200, configJSON(version: 3)))
        h.transport.on("/v1/app/records", .json(409, ["error": "config_outdated", "version": 3]))
        let consent = try h.make()
        _ = try await consent.acceptAll()
        XCTAssertEqual(consent.pendingCount, 0, "409 descarta o item")
        XCTAssertTrue(consent.needsConsent, "a decisão é de outro banner")
        // O cache foi invalidado: a próxima leitura busca o banner novo, mesmo dentro dos 60 s.
        let config = try await consent.loadConfig()
        XCTAssertEqual(config.version, 3)
        XCTAssertEqual(h.transport.requests(to: "/v1/app/config").count, 2)
    }

    func testNeedsConsentWithoutDecisionAndAfterExpiry() async throws {
        let h = Harness()
        h.transport.on("/v1/app/config", .json(200, configJSON(expiryDays: 30)))
        h.transport.on("/v1/app/records", .offline)
        let consent = try h.make()
        XCTAssertTrue(consent.needsConsent)
        XCTAssertFalse(consent.isGranted("analytics"))
        _ = try await consent.acceptAll()
        XCTAssertFalse(consent.needsConsent)
        h.clock.advance(30 * 86_400 + 1)
        XCTAssertTrue(consent.needsConsent, "sem recibo, vence por decidedAt + prazo do banner")
        XCTAssertFalse(consent.isGranted("analytics"))
    }

    func testReceiptExpiryWins() async throws {
        let h = Harness()
        h.transport.on("/v1/app/config", .json(200, configJSON(expiryDays: 730)))
        let soon = ISO8601DateFormatter().string(from: h.clock.now().addingTimeInterval(3_600))
        h.transport.on("/v1/app/records", .json(201, ["consentId": "id-1", "expiresAt": soon]))
        let consent = try h.make()
        _ = try await consent.acceptAll()
        h.clock.advance(3_601)
        XCTAssertTrue(consent.needsConsent)
    }

    func testQueueKeepsAtMostFiftyAndThirtyDays() async throws {
        let h = Harness()
        h.transport.on("/v1/app/config", .json(200, configJSON()))
        h.transport.on("/v1/app/records", .offline)
        let consent = try h.make()
        for _ in 0..<55 { _ = try await consent.acceptAll() }
        XCTAssertEqual(consent.pendingCount, 50)
        h.clock.advance(31 * 86_400)
        h.transport.on("/v1/app/config", .json(200, configJSON()))
        _ = try await consent.rejectAll()
        XCTAssertEqual(consent.pendingCount, 1, "os de mais de 30 dias saem")
    }

    func testObserversHearEveryChange() async throws {
        let h = Harness()
        h.transport.on("/v1/app/config", .json(200, configJSON()))
        h.transport.on("/v1/app/records", .json(201, receiptJSON))
        let consent = try h.make()
        let queue = DispatchQueue(label: "test")
        let lock = NSLock()
        var seen: [ConsentAction?] = []
        let initial = expectation(description: "inicial")
        let changes = expectation(description: "mudanças")
        changes.expectedFulfillmentCount = 2
        let observation = consent.observe(on: queue) { decision in
            lock.lock(); seen.append(decision?.action); let count = seen.count; lock.unlock()
            if count == 1 { initial.fulfill() } else if count <= 3 { changes.fulfill() }
        }
        await fulfillment(of: [initial], timeout: 2)
        _ = try await consent.rejectAll()
        await fulfillment(of: [changes], timeout: 2)
        lock.lock()
        XCTAssertEqual(seen.first!, nil)
        XCTAssertEqual(seen[1], .rejectAll, "na hora, antes do envio")
        lock.unlock()
        observation.cancel()
    }

    func testRevokeIsRecordedAsProof() async throws {
        let h = Harness()
        h.transport.on("/v1/app/config", .json(200, configJSON()))
        h.transport.on("/v1/app/records", .json(201, receiptJSON))
        let consent = try h.make()
        _ = try await consent.acceptAll()
        let revoked = try await consent.revoke()
        XCTAssertEqual(revoked.action, .revoke)
        XCTAssertFalse(consent.isGranted("analytics"))
        XCTAssertTrue(consent.isGranted("necessary"))
        let last = try XCTUnwrap(h.transport.requests(to: "/v1/app/records").last?.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: last) as? [String: Any])
        XCTAssertEqual(body["action"] as? String, "revoke")
    }

    func testInvalidChoicesDoNotTouchState() async throws {
        let h = Harness()
        h.transport.on("/v1/app/config", .json(200, configJSON()))
        let consent = try h.make()
        do {
            _ = try await consent.save(categories: ["necessary": false])
            XCTFail("recusar obrigatória")
        } catch {
            XCTAssertEqual(error as? TrustoConsentError, .requiredCategoryRefused("necessary"))
        }
        XCTAssertNil(consent.decision)
        XCTAssertEqual(consent.pendingCount, 0)
        XCTAssertTrue(h.transport.requests(to: "/v1/app/records").isEmpty)
    }
}
