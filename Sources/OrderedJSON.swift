import Foundation

/// 保留键的顺序和原始写法的 JSON 值。改写别人的配置文件（Claude Code、Codex 的钩子设置）时用：
/// 只动要改的那一段，其余的键按原来的顺序写回去。JSONSerialization 的字典不保留顺序，
/// 写回去会把整个文件的键重排一遍
indirect enum JSONValue {
    case null
    case bool(Bool)
    case number(String)              // 原文：1.0 不会变成 1，很大的整数也不会丢精度
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])
}

extension JSONValue: Equatable {
    static func == (a: JSONValue, b: JSONValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.number(let x), .number(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        case (.array(let x), .array(let y)): return x == y
        case (.object(let x), .object(let y)): return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }
}

enum JSONTextError: Error { case invalid(String) }

extension JSONValue {
    /// 解析一段 JSON 文本，不合法就抛错
    static func parse(_ text: String) throws -> JSONValue {
        var p = JSONParser(Array(text.utf8))
        let v = try p.value()
        p.skipSpace()
        guard p.atEnd else { throw JSONTextError.invalid("末尾还有多余的内容") }
        return v
    }

    /// 写成 JSON 文本：两格缩进（和 Claude Code 自己写 settings.json 的格式一样），空的数组、对象写成 [] / {}
    var text: String { rendered(depth: 0) }

    private func rendered(depth: Int) -> String {
        let pad = String(repeating: "  ", count: depth), inner = String(repeating: "  ", count: depth + 1)
        switch self {
        case .null: return "null"
        case .bool(let v): return v ? "true" : "false"
        case .number(let raw): return raw
        case .string(let s): return "\"" + JSONValue.escaped(s) + "\""
        case .array(let items):
            guard !items.isEmpty else { return "[]" }
            return "[\n" + items.map { inner + $0.rendered(depth: depth + 1) }.joined(separator: ",\n") + "\n" + pad + "]"
        case .object(let pairs):
            guard !pairs.isEmpty else { return "{}" }
            return "{\n" + pairs.map { inner + "\"" + JSONValue.escaped($0.0) + "\": " + $0.1.rendered(depth: depth + 1) }.joined(separator: ",\n") + "\n" + pad + "}"
        }
    }

    /// 字符串的转义：只转义引号、反斜杠和控制字符，中文、斜杠这些原样输出（和 JSON.stringify 一样）
    private static func escaped(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for u in s.unicodeScalars {
            switch u.value {
            case 0x22: out += "\\\""
            case 0x5c: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x0c: out += "\\f"
            case 0x0a: out += "\\n"
            case 0x0d: out += "\\r"
            case 0x09: out += "\\t"
            case 0x00...0x1f: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out
    }

    /// 对象里某个键的值；不是对象或没有这个键就是 nil
    subscript(key: String) -> JSONValue? {
        objectPairs?.first { $0.0 == key }?.1
    }

    /// 对象的各对键值，按原来的顺序；不是对象就是 nil
    var objectPairs: [(String, JSONValue)]? {
        if case .object(let pairs) = self { return pairs }
        return nil
    }

    /// 数组的各项；不是数组就是空的
    var items: [JSONValue] {
        if case .array(let a) = self { return a }
        return []
    }

    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// 改对象里某个键的值：键已经有了就原位改，没有就加在最后；传 nil 是删掉这个键
    mutating func set(_ key: String, _ value: JSONValue?) {
        guard var pairs = objectPairs else { return }
        if let i = pairs.firstIndex(where: { $0.0 == key }) {
            if let value { pairs[i].1 = value } else { pairs.remove(at: i) }
        } else if let value {
            pairs.append((key, value))
        }
        self = .object(pairs)
    }
}

private struct JSONParser {
    let b: [UInt8]
    var i = 0

    init(_ b: [UInt8]) { self.b = b }

    var atEnd: Bool { i >= b.count }

    mutating func skipSpace() {
        while i < b.count, [0x20, 0x09, 0x0a, 0x0d].contains(b[i]) { i += 1 }
    }

    mutating func value() throws -> JSONValue {
        skipSpace()
        guard !atEnd else { throw JSONTextError.invalid("内容不完整") }
        switch b[i] {
        case 0x7b: return try object()                // {
        case 0x5b: return try array()                 // [
        case 0x22: return .string(try string())       // "
        case 0x74: try literal("true"); return .bool(true)
        case 0x66: try literal("false"); return .bool(false)
        case 0x6e: try literal("null"); return .null
        default: return .number(try number())
        }
    }

    mutating func literal(_ word: String) throws {
        let w = Array(word.utf8)
        guard i + w.count <= b.count, Array(b[i..<i + w.count]) == w else { throw JSONTextError.invalid("不是合法的 JSON") }
        i += w.count
    }

    mutating func number() throws -> String {
        let start = i
        while i < b.count, [0x2b, 0x2d, 0x2e, 0x45, 0x65].contains(b[i]) || (0x30...0x39).contains(b[i]) { i += 1 }
        guard i > start else { throw JSONTextError.invalid("不是合法的 JSON") }
        let raw = String(decoding: b[start..<i], as: UTF8.self)
        // 只认 JSON 规定的写法：01、1e+、1. 这些不算，不然写回去的文件就不是合法的 JSON 了
        guard raw.wholeMatch(of: #/-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?/#) != nil else {
            throw JSONTextError.invalid("数字的写法不对")
        }
        return raw
    }

    mutating func string() throws -> String {
        i += 1   // 开头的引号
        var out = [UInt8]()
        while i < b.count {
            let c = b[i]
            if c == 0x22 { i += 1; return String(decoding: out, as: UTF8.self) }
            if c != 0x5c {
                // 字符串里不能直接出现控制字符，制表、换行这些得写成转义
                guard c >= 0x20 else { throw JSONTextError.invalid("字符串里有没转义的控制字符") }
                out.append(c); i += 1; continue
            }
            i += 1
            guard !atEnd else { break }
            switch b[i] {
            case 0x22: out.append(0x22)
            case 0x5c: out.append(0x5c)
            case 0x2f: out.append(0x2f)
            case 0x62: out.append(0x08)
            case 0x66: out.append(0x0c)
            case 0x6e: out.append(0x0a)
            case 0x72: out.append(0x0d)
            case 0x74: out.append(0x09)
            case 0x75:
                let hi = try hex4()
                var scalar = hi
                if (0xd800...0xdbff).contains(hi) {   // 高代理项：后面必须跟一个低代理项
                    guard i + 2 < b.count, b[i + 1] == 0x5c, b[i + 2] == 0x75 else { throw JSONTextError.invalid("不完整的代理对") }
                    i += 2
                    let lo = try hex4()
                    guard (0xdc00...0xdfff).contains(lo) else { throw JSONTextError.invalid("不完整的代理对") }
                    scalar = 0x10000 + (hi - 0xd800) * 0x400 + (lo - 0xdc00)
                }
                guard let s = Unicode.Scalar(scalar) else { throw JSONTextError.invalid("不合法的字符") }
                out += Array(String(s).utf8)
            default: throw JSONTextError.invalid("不认识的转义")
            }
            i += 1
        }
        throw JSONTextError.invalid("字符串没有结束")
    }

    /// \uXXXX 的四位十六进制；读完 i 停在最后一位上
    mutating func hex4() throws -> UInt32 {
        guard i + 4 < b.count else { throw JSONTextError.invalid("\\u 后面不够四位") }
        var n: UInt32 = 0
        for k in 1...4 {
            let c = b[i + k]
            let d: UInt32
            switch c {
            case 0x30...0x39: d = UInt32(c - 0x30)
            case 0x41...0x46: d = UInt32(c - 0x37)      // A-F
            case 0x61...0x66: d = UInt32(c - 0x57)      // a-f
            default: throw JSONTextError.invalid("\\u 后面不是十六进制")
            }
            n = n * 16 + d
        }
        i += 4
        return n
    }

    mutating func array() throws -> JSONValue {
        i += 1
        var items: [JSONValue] = []
        skipSpace()
        if !atEnd, b[i] == 0x5d { i += 1; return .array(items) }
        while true {
            items.append(try value())
            skipSpace()
            guard !atEnd else { throw JSONTextError.invalid("数组没有结束") }
            if b[i] == 0x2c { i += 1; continue }
            if b[i] == 0x5d { i += 1; return .array(items) }
            throw JSONTextError.invalid("数组里缺了逗号")
        }
    }

    mutating func object() throws -> JSONValue {
        i += 1
        var pairs: [(String, JSONValue)] = []
        skipSpace()
        if !atEnd, b[i] == 0x7d { i += 1; return .object(pairs) }
        while true {
            skipSpace()
            guard !atEnd, b[i] == 0x22 else { throw JSONTextError.invalid("键要是字符串") }
            let key = try string()
            skipSpace()
            guard !atEnd, b[i] == 0x3a else { throw JSONTextError.invalid("键后面缺冒号") }
            i += 1
            let value = try value()
            // 重复的键以最后一个为准（JSONSerialization、Claude Code 都这么读），位置留在第一次出现的地方
            if let k = pairs.firstIndex(where: { $0.0 == key }) { pairs[k].1 = value } else { pairs.append((key, value)) }
            skipSpace()
            guard !atEnd else { throw JSONTextError.invalid("对象没有结束") }
            if b[i] == 0x2c { i += 1; continue }
            if b[i] == 0x7d { i += 1; return .object(pairs) }
            throw JSONTextError.invalid("对象里缺了逗号")
        }
    }
}
