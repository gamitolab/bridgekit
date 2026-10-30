// StateStoreObserveTests.swift
// Replay-latest semantics for StateStore.observe — the path JS StateMirror uses
// (BridgeState.observe → Router.stateObserve).
//
// observe() used to only register the callback, so a JS mirror that subscribed
// after the value changed kept its previous snapshot until the next change. A
// provider backed by a state stream that never re-emits an equal value left the
// mirror stale indefinitely. observe() must deliver the current value first.

import XCTest

@testable import BridgeKit

final class StateStoreObserveTests: XCTestCase {
    // StateStore borrows the engine lock as `unowned(unsafe)`; keep it alive.
    private var lock = NSRecursiveLock()

    private let contractId = "bridgekit.test-state"
    private let stateKey = "profile"
    private let scope = Scope.global

    func test_observeDeliversCurrentValueImmediately() {
        let store = StateStore(lock: lock)
        store.seedNativeState(contractId: contractId, scope: scope, stateKey: stateKey, initial: "a")
        store.setNativeValue(contractId: contractId, scope: scope, stateKey: stateKey, value: "b")

        var received: [Any?] = []
        _ = store.observe(contractId: contractId, scope: scope, stateKey: stateKey, epoch: 1) { env in
            received.append(env["v"] ?? nil)
        }

        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first as? String, "b")
    }

    func test_reObservingAfterUnobservedChangeDeliversLatestValue() {
        let store = StateStore(lock: lock)
        store.seedNativeState(contractId: contractId, scope: scope, stateKey: stateKey, initial: "a")
        let first = store.observe(contractId: contractId, scope: scope, stateKey: stateKey, epoch: 1) { _ in }
        store.unobserve(first)
        store.setNativeValue(contractId: contractId, scope: scope, stateKey: stateKey, value: "b")

        var received: Any?
        _ = store.observe(contractId: contractId, scope: scope, stateKey: stateKey, epoch: 1) { env in
            received = env["v"] ?? nil
        }

        XCTAssertEqual(received as? String, "b")
    }

    func test_observeDeliversJsProvidedValueImmediately() {
        let store = StateStore(lock: lock)
        store.writeFromJs(contractId: contractId, scope: scope, stateKey: stateKey, value: 42, nativeOwnsBinding: false)

        var received: Any?
        _ = store.observe(contractId: contractId, scope: scope, stateKey: stateKey, epoch: 1) { env in
            received = env["v"] ?? nil
        }

        XCTAssertEqual(received as? Int, 42)
    }

    func test_observeDoesNotEmitWithoutAvailableValue() {
        let store = StateStore(lock: lock)
        var callCount = 0
        _ = store.observe(contractId: contractId, scope: scope, stateKey: stateKey, epoch: 1) { _ in
            callCount += 1
        }
        XCTAssertEqual(callCount, 0)

        store.seedNativeState(contractId: contractId, scope: scope, stateKey: "other", initial: "a")
        _ = store.markUnprovided(contractId: contractId, scope: scope)
        _ = store.observe(contractId: contractId, scope: scope, stateKey: "other", epoch: 1) { _ in
            callCount += 1
        }
        XCTAssertEqual(callCount, 0)
    }
}
