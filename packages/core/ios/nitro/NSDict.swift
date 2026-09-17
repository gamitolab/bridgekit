// NSDict.swift — [String: Any?] ↔ module-imported NSDictionary.
//
// When BKTransport.h is imported via the Clang module (frameworks / DEFINES_MODULE),
// NSDictionary surfaces as [AnyHashable: Any], not as NSDictionary / [String: Any?].

import Foundation

enum NSDict {
    static func fromMap(_ map: [String: Any?]) -> [AnyHashable: Any] {
        var out: [AnyHashable: Any] = [:]
        for (key, value) in map {
            out[key] = value ?? NSNull()
        }
        return out
    }

    static func toMap(_ dict: [AnyHashable: Any]) -> [String: Any?] {
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
}
