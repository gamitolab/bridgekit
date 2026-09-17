// NSDict.swift — [String: Any?] ↔ NSDictionary for the C/ObjC transport seam.

import Foundation

enum NSDict {
    static func fromMap(_ map: [String: Any?]) -> NSDictionary {
        let out = NSMutableDictionary()
        for (key, value) in map {
            out[key] = value ?? NSNull()
        }
        return out
    }

    static func toMap(_ dict: NSDictionary) -> [String: Any?] {
        var out: [String: Any?] = [:]
        dict.enumerateKeysAndObjects { key, value, _ in
            guard let k = key as? String else { return }
            out[k] = value is NSNull ? nil : value
        }
        return out
    }
}
