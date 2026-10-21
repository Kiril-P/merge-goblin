//  JSON.swift — a reader that never throws and never traps.
//
//  Parsing is by hand rather than Codable on purpose: the engine is a different
//  program, on a different release cadence, writing these files. A document that is
//  one key short, or has a number where a string was expected, must degrade to a
//  sensible default rather than fail a whole decode and blank the UI.

import Foundation

/// Tree walker that never throws and never traps. Every accessor returns nil (or
/// an empty collection) for "absent, or not the type I wanted".
struct JSON {
    let raw: Any?

    init(_ raw: Any?) {
        if let raw, raw is NSNull { self.raw = nil } else { self.raw = raw }
    }

    static func parse(_ data: Data) -> JSON {
        JSON(try? JSONSerialization.jsonObject(with: data, options: []))
    }

    static func parse(_ text: String) -> JSON {
        guard let data = text.data(using: .utf8) else { return JSON(nil) }
        return parse(data)
    }

    static func read(path: String) -> JSON {
        guard let data = FileManager.default.contents(atPath: path) else { return JSON(nil) }
        return parse(data)
    }

    subscript(key: String) -> JSON {
        JSON((raw as? [String: Any])?[key])
    }

    subscript(index: Int) -> JSON {
        guard let array = raw as? [Any], index >= 0, index < array.count else { return JSON(nil) }
        return JSON(array[index])
    }

    var exists: Bool { raw != nil }
    var string: String? { raw as? String }
    var array: [JSON] { (raw as? [Any])?.map(JSON.init) ?? [] }
    var object: [String: Any]? { raw as? [String: Any] }

    var int: Int? {
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String { return Int(s) }
        return nil
    }

    var double: Double? {
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String { return Double(s) }
        return nil
    }

    var bool: Bool? {
        if let n = raw as? NSNumber { return n.boolValue }
        if let s = raw as? String { return s == "true" || s == "yes" || s == "1" }
        return nil
    }

    func string(_ fallback: String) -> String { string ?? fallback }
    func int(_ fallback: Int) -> Int { int ?? fallback }
    func bool(_ fallback: Bool) -> Bool { bool ?? fallback }
    func double(_ fallback: Double) -> Double { double ?? fallback }
}

