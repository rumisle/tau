import Foundation

/// JSON as JSONSerialization produces it ([String: Any], [Any], String, NSNumber, NSNull), with typed accessors.
/// Docs arrive as snapshots plus ops that address arbitrary paths, so a dynamic tree is the natural shape.
typealias JSONObject = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        return self[key] as? String
    }

    func int(_ key: String) -> Int? {
        return (self[key] as? NSNumber)?.intValue
    }

    func double(_ key: String) -> Double? {
        return (self[key] as? NSNumber)?.doubleValue
    }

    func bool(_ key: String) -> Bool? {
        return (self[key] as? NSNumber)?.boolValue
    }

    func object(_ key: String) -> JSONObject? {
        return self[key] as? JSONObject
    }

    func array(_ key: String) -> [Any]? {
        return self[key] as? [Any]
    }

    func objects(_ key: String) -> [JSONObject] {
        return (self[key] as? [Any])?.compactMap { $0 as? JSONObject } ?? []
    }
}

enum JSONOps {
    enum Error: Swift.Error {
        case badOp(String)
    }

    /// Applies protocol ops (docs/protocol.md, "Ops") to `root` in order.
    static func apply(_ ops: [Any], to root: Any) throws -> Any {
        var root = root
        for case let op as [Any] in ops {
            guard let kind = op.first as? String else {
                throw Error.badOp("\(op)")
            }
            if kind == "r" {
                root = op.count > 1 ? op[1] : NSNull()
                continue
            }
            guard op.count >= 2, let path = op[1] as? [Any] else {
                throw Error.badOp("\(op)")
            }
            root = try self.update(root, path: path[...]) { value in
                switch kind {
                case "s":
                    return .set(op.count > 2 ? op[2] : NSNull())
                case "d":
                    return .delete
                case "a":
                    return .set(((value as? String) ?? "") + ((op.count > 2 ? op[2] : "") as? String ?? ""))
                case "t":
                    let string = (value as? String) ?? ""
                    let count = (op.count > 2 ? op[2] as? NSNumber : nil)?.intValue ?? 0
                    // UTF-16 code units, as the server counts.
                    let utf16 = Array(string.utf16)
                    return .set(String(utf16CodeUnits: Array(utf16.dropFirst(min(count, utf16.count))), count: max(0, utf16.count - count)))
                case "p":
                    var array = (value as? [Any]) ?? []
                    let index = (op[2] as? NSNumber)?.intValue ?? 0
                    let deleteCount = (op[3] as? NSNumber)?.intValue ?? 0
                    let items = (op.count > 4 ? op[4] as? [Any] : nil) ?? []
                    let start = min(max(0, index), array.count)
                    let end = min(array.count, start + deleteCount)
                    array.replaceSubrange(start ..< end, with: items)
                    return .set(array)
                case "m":
                    let array = (value as? [Any]) ?? []
                    let permutation = (op[2] as? [Any])?.compactMap { ($0 as? NSNumber)?.intValue } ?? []
                    return .set(permutation.compactMap { $0 < array.count ? array[$0] : nil })
                default:
                    throw Error.badOp(kind)
                }
            }
        }
        return root
    }

    private enum Change {
        case set(Any)
        case delete
    }

    /// Rebuilds the containers along `path`, applying `change` to the value at its end. A delete at an array index
    /// removes the element.
    private static func update(_ node: Any?, path: ArraySlice<Any>, change: (Any?) throws -> Change) throws -> Any {
        guard let key = path.first else {
            switch try change(node) {
            case let .set(value):
                return value
            case .delete:
                return NSNull()
            }
        }
        let rest = path.dropFirst()
        if let index = (key as? NSNumber)?.intValue, !(key is String) {
            var array = (node as? [Any]) ?? []
            if rest.isEmpty {
                let current: Any? = index < array.count ? array[index] : nil
                switch try change(current) {
                case let .set(value):
                    if index < array.count {
                        array[index] = value
                    } else {
                        array.append(value)
                    }
                case .delete:
                    if index < array.count {
                        array.remove(at: index)
                    }
                }
            } else if index < array.count {
                array[index] = try self.update(array[index], path: rest, change: change)
            }
            return array
        }
        let name = (key as? String) ?? "\(key)"
        var object = (node as? JSONObject) ?? [:]
        if rest.isEmpty {
            switch try change(object[name]) {
            case let .set(value):
                object[name] = value
            case .delete:
                object.removeValue(forKey: name)
            }
        } else {
            object[name] = try self.update(object[name], path: rest, change: change)
        }
        return object
    }
}
