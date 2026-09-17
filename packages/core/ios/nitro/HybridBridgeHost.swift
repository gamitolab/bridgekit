// HybridBridgeHost.swift
// BridgeKit iOS — Nitro Hybrid implementation for BridgeHost.
//
// CLASS NAME: MUST be HybridBridgeHost — BridgeKitNitroAutolinking.swift instantiates by exact name.
// A rename here silently breaks Nitro autolinking.
//
// Requires @_implementationOnly import NitroModules (only available inside the pod build).

@_implementationOnly import NitroModules

// Double-Promise adapter (connectDispatcher / onInvoke)
//
// Nitro generates `onInvoke` as (AnyMap) -> Promise<Promise<AnyMap>>:
//   - Inner Promise<AnyMap> resolves when JS finishes.
//   - Outer Promise wraps the cross-thread Nitro dispatch.
//
// Bridged to JsDispatcherCallbacks.onInvoke's completion-callback API via a
// detached Task that peels both layers with `.await().await()` and calls
// completion exactly once (do/catch wrapper).

final class HybridBridgeHost: HybridBridgeHostSpec {

    // `override` (not `required`) — HybridBridgeHostSpec_base.init() is not required.
    override init() {
        super.init()
    }

    // MARK: - invoke

    /// Async invoke — returns a Promise resolved when the delegate's completion fires.
    func invoke(env: AnyMap) throws -> Promise<AnyMap> {
        return Promise.async {
            let envMap = AnyMapCodec.fromAnyMap(env)

            // Suspend until the delegate fires the completion callback.
            let resultMap: [String: Any?] = try await withCheckedThrowingContinuation { continuation in
                BKTransportInvoke(NSDict.fromMap(envMap)) { result in
                    continuation.resume(returning: NSDict.toMap(result))
                }
            }

            return try AnyMapCodec.toAnyMap(resultMap)
        }
    }

    // MARK: - invokeSync

    /// Synchronous invoke — blocks the calling thread until delegate returns.
    func invokeSync(env: AnyMap) throws -> AnyMap {
        let envMap  = AnyMapCodec.fromAnyMap(env)
        let result  = NSDict.toMap(BKTransportInvokeSync(NSDict.fromMap(envMap)))
        return try AnyMapCodec.toAnyMap(result)
    }

    // MARK: - connectDispatcher

    /// Register the JS dispatcher. Synchronous — returns epoch + snapshot envelope.
    /// onInvoke uses Nitro's double-Promise signature — see the Double-Promise adapter
    /// comment at the top of this file.
    func connectDispatcher(
        epochInfo: AnyMap,
        onInvoke: @escaping (_ env: AnyMap) -> Promise<Promise<AnyMap>>,
        onStreamOpen: @escaping (_ env: AnyMap) -> Void,
        onStreamClose: @escaping (_ env: AnyMap) -> Void,
        onStateWrite: @escaping (_ env: AnyMap) -> Void
    ) throws -> AnyMap {
        let epochMap = AnyMapCodec.fromAnyMap(epochInfo)
        let result = NSDict.toMap(BKTransportConnectDispatcher(
            NSDict.fromMap(epochMap),
            { envNS, completion in
                let envMap = NSDict.toMap(envNS)
                let nitroEnv: AnyMap
                do {
                    nitroEnv = try AnyMapCodec.toAnyMap(envMap)
                } catch {
                    completion(nil, error)
                    return
                }
                Task {
                    do {
                        let resultAnyMap = try await onInvoke(nitroEnv).await().await()
                        completion(NSDict.fromMap(AnyMapCodec.fromAnyMap(resultAnyMap)), nil)
                    } catch {
                        completion(nil, error)
                    }
                }
            },
            { envNS in
                do {
                    onStreamOpen(try AnyMapCodec.toAnyMap(NSDict.toMap(envNS)))
                } catch {
                    SeamEncoding.reportFailure(context: "stream open", error: error)
                }
            },
            { envNS in
                do {
                    onStreamClose(try AnyMapCodec.toAnyMap(NSDict.toMap(envNS)))
                } catch {
                    SeamEncoding.reportFailure(context: "stream close", error: error)
                }
            },
            { envNS in
                do {
                    onStateWrite(try AnyMapCodec.toAnyMap(NSDict.toMap(envNS)))
                } catch {
                    SeamEncoding.reportFailure(context: "state write", error: error)
                }
            }
        ))
        return try AnyMapCodec.toAnyMap(result)
    }
}
