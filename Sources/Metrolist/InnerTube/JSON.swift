import Foundation

/// Lightweight dynamic JSON accessor. InnerTube responses are deeply nested and shift often,
/// so optional chaining over untyped values is more resilient than Codable models.
@dynamicMemberLookup
struct JSON {
    let raw: Any?

    init(_ raw: Any?) {
        self.raw = raw is NSNull ? nil : raw
    }

    init(data: Data) {
        self.init(try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    subscript(key: String) -> JSON {
        JSON((raw as? [String: Any])?[key])
    }

    subscript(index: Int) -> JSON {
        guard let array = raw as? [Any], array.indices.contains(index) else { return JSON(nil) }
        return JSON(array[index])
    }

    subscript(dynamicMember key: String) -> JSON {
        self[key]
    }

    var exists: Bool { raw != nil }
    var string: String? { raw as? String }
    var bool: Bool? { raw as? Bool }
    var array: [JSON] { (raw as? [Any])?.map(JSON.init) ?? [] }
    var dictionary: [String: Any]? { raw as? [String: Any] }

    var int: Int? {
        if let number = raw as? NSNumber { return number.intValue }
        if let string = raw as? String { return Int(string) }
        return nil
    }

    var double: Double? {
        if let number = raw as? NSNumber { return number.doubleValue }
        if let string = raw as? String { return Double(string) }
        return nil
    }

    /// Concatenated text of a `{runs: [{text}]}` or `{simpleText}` object.
    var text: String? {
        let runs = self["runs"].array
        if runs.isEmpty { return self["simpleText"].string }
        return runs.compactMap { $0["text"].string }.joined()
    }

    /// Depth-first search for the first value stored under `key`.
    func first(_ key: String) -> JSON {
        if let dictionary = raw as? [String: Any] {
            if let value = dictionary[key], !(value is NSNull) { return JSON(value) }
            for value in dictionary.values {
                let found = JSON(value).first(key)
                if found.exists { return found }
            }
        } else if let array = raw as? [Any] {
            for value in array {
                let found = JSON(value).first(key)
                if found.exists { return found }
            }
        }
        return JSON(nil)
    }

    /// Collects every value stored under one of `keys`, without descending into matches.
    /// Array order is preserved; sibling dictionary keys are visited in sorted order.
    func collect(_ keys: Set<String>) -> [(key: String, value: JSON)] {
        var result: [(key: String, value: JSON)] = []
        collect(keys, into: &result)
        return result
    }

    private func collect(_ keys: Set<String>, into result: inout [(key: String, value: JSON)]) {
        if let dictionary = raw as? [String: Any] {
            for key in dictionary.keys.sorted() {
                guard let value = dictionary[key] else { continue }
                if keys.contains(key) {
                    result.append((key, JSON(value)))
                } else {
                    JSON(value).collect(keys, into: &result)
                }
            }
        } else if let array = raw as? [Any] {
            for value in array { JSON(value).collect(keys, into: &result) }
        }
    }
}
