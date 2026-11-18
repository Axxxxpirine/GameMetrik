import Foundation
import CZlib

// All provider files stay in memory; no subprocess or temporary report on disk.
enum ReportFormats {
    static let limit = 64 * 1024 * 1024
    static func inflate(_ data: Data, window: Int32) throws -> Data {
        guard data.count <= limit else { throw invalid() }
        var stream = z_stream()
        guard inflateInit2_(&stream, window, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw invalid() }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { raw in
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var output = Data(); var chunk = [UInt8](repeating: 0, count: 32768)
            var status: Int32 = Z_OK
            repeat {
                try Task.checkCancellation()
                status = chunk.withUnsafeMutableBytes { bytes in
                    stream.next_out = bytes.bindMemory(to: Bytef.self).baseAddress; stream.avail_out = uInt(bytes.count)
                    return CZlib.inflate(&stream, Z_NO_FLUSH)
                }
                guard status == Z_OK || status == Z_STREAM_END else { throw invalid() }
                let count = chunk.count - Int(stream.avail_out)
                guard output.count + count <= limit, count > 0 || status == Z_STREAM_END else { throw invalid() }
                output.append(contentsOf: chunk.prefix(count))
            } while status != Z_STREAM_END
            guard stream.avail_in == 0 else { throw invalid() }
            return output
        }
    }
    static func files(_ data: Data) throws -> [Data] {
        guard data.count <= limit else { throw invalid() }
        if data.starts(with: [0x1f, 0x8b]) { return [try inflate(data, window: 31)] }
        guard data.starts(with: [0x50, 0x4b]) else { return [data] }
        let b = [UInt8](data)
        func number(_ offset: Int, _ size: Int) throws -> Int {
            guard offset >= 0, offset + size <= b.count else { throw invalid() }
            return (0..<size).reduce(0) { $0 | Int(b[offset+$1]) << (8*$1) }
        }
        guard b.count >= 22, let end = stride(from: b.count-22, through: max(0,b.count-65557), by: -1).first(where: { b[$0..<$0+4].elementsEqual([0x50,0x4b,0x05,0x06]) }) else { throw invalid() }
        guard try number(end+4,2) == 0, try number(end+6,2) == 0, try number(end+8,2) == number(end+10,2) else { throw invalid() }
        let count = try number(end+10,2); var offset = try number(end+16,4)
        guard count > 0, count <= 100 else { throw invalid() }
        var result: [Data] = []; var total = 0
        for _ in 0..<count {
            guard try number(offset,4) == 0x02014b50, try number(offset+8,2) & 1 == 0 else { throw invalid() }
            let method = try number(offset+10,2), compressed = try number(offset+20,4), size = try number(offset+24,4)
            let nameSize = try number(offset+28,2), extra = try number(offset+30,2), comment = try number(offset+32,2)
            let local = try number(offset+42,4), crc = try number(offset+16,4)
            guard size <= limit, compressed <= limit, try number(local,4) == 0x04034b50 else { throw invalid() }
            let start = try local+30+number(local+26,2)+number(local+28,2)
            guard start+compressed <= b.count, offset+46+nameSize <= b.count else { throw invalid() }
            let name = String(decoding: b[offset+46..<offset+46+nameSize], as: UTF8.self)
            if name.lowercased().hasSuffix(".csv") {
                let payload = Data(b[start..<start+compressed])
                let decoded: Data
                if method == 0 { decoded = payload } else if method == 8 { decoded = try inflate(payload, window: -15) } else { throw invalid() }
                let checksum = decoded.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(decoded.count)) }
                guard decoded.count == size, checksum == uLong(crc), total+size <= limit else { throw invalid() }
                total += size; result.append(decoded)
            }
            offset += 46+nameSize+extra+comment
        }
        guard !result.isEmpty else { throw invalid() }; return result
    }
    static func table(_ data: Data, separator: Character = ",", required: [String] = []) throws -> [[String: String]] {
        let text: String?
        if data.starts(with: [0xff,0xfe]) || data.starts(with: [0xfe,0xff]) { text = String(data: data, encoding: .utf16) }
        else { text = String(data: data, encoding: .utf8) }
        guard let text, data.count <= limit else { throw invalid() }
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false, closed = false
        let chars = Array(text.replacingOccurrences(of: "\u{feff}", with: "")); var i = 0
        while i < chars.count {
            let ch = chars[i]
            if quoted {
                if ch == "\"" {
                    if i+1 < chars.count, chars[i+1] == "\"" { field.append(ch); i += 1 }
                    else { quoted = false; closed = true }
                } else { field.append(ch) }
            } else if ch == separator { row.append(field); field = ""; closed = false }
            else if ch == "\n" || ch == "\r\n" || ch == "\r" {
                row.append(field); if row.contains(where: { !$0.isEmpty }) { rows.append(row) }; row = []; field = ""; closed = false
            } else if ch == "\"", field.isEmpty, !closed { quoted = true }
            else { guard !closed, ch != "\"" else { throw invalid() }; field.append(ch) }
            i += 1
        }
        guard !quoted else { throw invalid() }
        row.append(field); if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        guard let first = rows.first else { throw invalid() }
        let header = first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard Set(header).count == header.count, Set(required).isSubset(of: Set(header)) else { throw invalid() }
        return try rows.dropFirst().map { row in
            guard row.count == header.count else { throw invalid() }
            return Dictionary(uniqueKeysWithValues: zip(header, row))
        }
    }
    static func decimal(_ text: String?) throws -> Decimal {
        guard let text, text.range(of: #"^-?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)$"#, options: .regularExpression) != nil,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else { throw invalid() }
        return value
    }
    static func invalid() -> GameMetrikError { .message("Rapport fournisseur incomplet ou format non reconnu. Aucun total n’a été inventé.") }
}
