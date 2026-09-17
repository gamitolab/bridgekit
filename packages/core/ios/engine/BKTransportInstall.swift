// BKTransportInstall.swift
// Registers the in-process Router as the process-wide transport seam so
// BridgeKitNitro (a different module, possibly a different binary) can reach it
// without importing this Swift module.

import Foundation
#if canImport(BridgeKitSeam)
import BridgeKitSeam
#endif

func BKTransportInstallHooks(_ router: Router) {
    let hooks = BKTransportHooks()

    hooks.invoke = { env, complete in
        router.invoke(env: nsToMap(env), complete: { result in
            complete(mapToNS(result))
        })
    }

    hooks.invokeSync = { env in
        mapToNS(router.invokeSync(env: nsToMap(env)))
    }

    hooks.connectDispatcher = { epochInfo, onInvoke, onStreamOpen, onStreamClose, onStateWrite in
        let callbacks = JsDispatcherCallbacks(
            onInvoke: { env, completion in
                onInvoke(mapToNS(env)) { ok, err in
                    completion(ok.map { nsToMap($0) }, err)
                }
            },
            onStreamOpen: { env in onStreamOpen(mapToNS(env)) },
            onStreamClose: { env in onStreamClose(mapToNS(env)) },
            onStateWrite: { env in onStateWrite(mapToNS(env)) }
        )
        return mapToNS(router.connectDispatcher(epochInfo: nsToMap(epochInfo), callbacks: callbacks))
    }

    hooks.openStream = { env, onNext, onEnd in
        router.openStream(
            env: nsToMap(env),
            onNext: { onNext(mapToNS($0)) },
            onEnd: { onEnd(mapToNS($0)) }
        ) as NSString as String
    }

    hooks.closeStream = { streamId in
        router.closeStream(streamId: streamId)
    }

    hooks.emitFromJs = { streamId, value in
        router.emitFromJs(streamId: streamId, value: nsToMap(value))
    }

    hooks.endFromJs = { streamId, end in
        router.endFromJs(streamId: streamId, end: nsToMap(end))
    }

    hooks.stateRead = { env in
        mapToNS(router.stateRead(env: nsToMap(env)))
    }

    hooks.stateObserve = { env, onChange in
        router.stateObserve(env: nsToMap(env), onChange: { onChange(mapToNS($0)) })
    }

    hooks.stateUnobserve = { obsId in
        router.stateUnobserve(obsId: obsId)
    }

    hooks.stateWrite = { env in
        mapToNS(router.stateWrite(env: nsToMap(env)))
    }

    BKTransportInstall(hooks)
}

private func nsToMap(_ dict: [AnyHashable: Any]) -> [String: Any?] {
    var out: [String: Any?] = [:]
    for (key, value) in dict {
        guard let k = key as? String else { continue }
        if value is NSNull {
            out[k] = nil
        } else {
            out[k] = value
        }
    }
    return out
}

private func mapToNS(_ map: [String: Any?]) -> [AnyHashable: Any] {
    var out: [AnyHashable: Any] = [:]
    for (key, value) in map {
        out[key] = value ?? NSNull()
    }
    return out
}
