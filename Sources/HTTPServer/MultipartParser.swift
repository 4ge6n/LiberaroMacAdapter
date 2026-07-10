import Foundation

struct MultipartPart {
    var filename: String?
    var contentType: String
    var body: Data
}

enum MultipartParser {
    /// `multipart/form-data; boundary=xxx` から boundary を取り出す。クォート付きにも対応。
    static func extractBoundary(contentType: String) -> String? {
        guard let range = contentType.range(of: "boundary=") else { return nil }
        var value = String(contentType[range.upperBound...])
        if let semi = value.firstIndex(of: ";") {
            value = String(value[value.startIndex..<semi])
        }
        value = value.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value.isEmpty ? nil : value
    }

    /// mac-sidecar の Python 実装 (`_parse_multipart`) と同じ最小実装。
    /// `image` (ファイル) + `meta` (JSON テキスト) の2パートだけを想定する。
    static func parse(body: Data, boundary: String) -> [String: MultipartPart]? {
        let boundaryBytes = Data(("--" + boundary).utf8)
        let endMarker = boundaryBytes + Data("--".utf8)
        guard let endRange = body.range(of: endMarker, options: .backwards) else { return nil }
        let trimmedBody = body.subdata(in: body.startIndex..<endRange.lowerBound)

        var parts: [String: MultipartPart] = [:]
        var searchStart = trimmedBody.startIndex
        var rawChunks: [Data] = []
        while let range = trimmedBody.range(of: boundaryBytes, in: searchStart..<trimmedBody.endIndex) {
            let chunk = trimmedBody.subdata(in: searchStart..<range.lowerBound)
            rawChunks.append(chunk)
            searchStart = range.upperBound
        }
        rawChunks.append(trimmedBody.subdata(in: searchStart..<trimmedBody.endIndex))

        let crlf = Data("\r\n".utf8)
        let doubleCRLF = Data("\r\n\r\n".utf8)

        for var raw in rawChunks {
            if raw.starts(with: crlf) {
                raw = raw.subdata(in: raw.index(raw.startIndex, offsetBy: 2)..<raw.endIndex)
            }
            if raw.count >= 2, raw.suffix(2) == crlf {
                raw = raw.subdata(in: raw.startIndex..<raw.index(raw.endIndex, offsetBy: -2))
            }
            if raw.isEmpty { continue }
            guard let sepRange = raw.range(of: doubleCRLF) else { continue }
            let headerBlob = raw.subdata(in: raw.startIndex..<sepRange.lowerBound)
            let payload = raw.subdata(in: sepRange.upperBound..<raw.endIndex)
            guard let headerText = String(data: headerBlob, encoding: .utf8) else { continue }

            var headers: [String: String] = [:]
            for line in headerText.components(separatedBy: "\r\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
            guard let disposition = headers["content-disposition"] else { continue }
            guard let name = extractQuoted(field: "name", from: disposition) else { continue }
            let filename = extractQuoted(field: "filename", from: disposition)
            parts[name] = MultipartPart(
                filename: filename,
                contentType: headers["content-type"] ?? "application/octet-stream",
                body: payload
            )
        }
        return parts
    }

    private static func extractQuoted(field: String, from source: String) -> String? {
        guard let fieldRange = source.range(of: "\(field)=\"") else { return nil }
        let afterQuote = source[fieldRange.upperBound...]
        guard let closingQuote = afterQuote.firstIndex(of: "\"") else { return nil }
        return String(afterQuote[afterQuote.startIndex..<closingQuote])
    }
}
