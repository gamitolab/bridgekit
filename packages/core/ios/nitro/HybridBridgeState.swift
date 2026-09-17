// HybridBridgeState.swift
// BridgeKit iOS — Nitro Hybrid implementation for BridgeState.
//
// CLASS NAME: MUST be HybridBridgeState — BridgeKitNitroAutolinking.swift instantiates by exact name.
//
// Requires @_implementationOnly import NitroModules (only available inside the pod build).

@_implementationOnly import NitroModules

/// Nitro Hybrid implementation for BridgeState.
/// Delegates all operations to the process-wide BKTransport seam.
final class HybridBridgeState: HybridBridgeStateSpec {

    // `override` (not `required`) — HybridBridgeStateSpec_base.init() is not required.
    override init() {
        super.init()
    }

    // MARK: - read

    /// Synchronous state read.
    /// Returns a ResultEnvelope map — { ok: true, v: <encoded-value> } or error envelope.
    func read(env: AnyMap) throws -> AnyMap {
        let result = NSDict.toMap(BKTransportStateRead(NSDict.fromMap(AnyMapCodec.fromAnyMap(env))))
        return try AnyMapCodec.toAnyMap(result)
    }

    // MARK: - observe

    /// Subscribe to state changes. Returns an epoch-scoped obsId.
    /// The onChange closure receives { v: <encoded-value> } envelopes.
    func observe(env: AnyMap, onChange: @escaping (_ value: AnyMap) -> Void) throws -> String {
        return BKTransportStateObserve(
            NSDict.fromMap(AnyMapCodec.fromAnyMap(env)),
            { valueNS in
                do {
                    onChange(try AnyMapCodec.toAnyMap(NSDict.toMap(valueNS)))
                } catch {
                    SeamEncoding.reportFailure(context: "state change", error: error)
                }
            }
        ) as String
    }

    // MARK: - unobserve

    /// Cancel a state observation. No-op if obsId is unknown or stale.
    func unobserve(obsId: String) throws -> Void {
        BKTransportStateUnobserve(obsId)
    }

    // MARK: - write

    /// Provider-side state write from JS. Returns a ResultEnvelope map.
    func write(env: AnyMap) throws -> AnyMap {
        let result = NSDict.toMap(BKTransportStateWrite(NSDict.fromMap(AnyMapCodec.fromAnyMap(env))))
        return try AnyMapCodec.toAnyMap(result)
    }
}
