import Foundation

/// サービスごとの Bearer トークンを生成・永続化する。
/// Python 版サイドカーの `secrets.token_urlsafe(32)` 相当（256bit 乱数を base64url、パディング無し）。
enum AuthTokenStore {
    static func loadOrCreate(fileURL: URL) -> String {
        if let existing = try? String(contentsOf: fileURL, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let token = generate()
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? (token + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return token
    }

    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes).base64URLEncodedString()
    }

    static func isAuthorized(headers: [String: String], token: String) -> Bool {
        guard !token.isEmpty else { return false }
        let supplied = extractToken(headers: headers)
        guard !supplied.isEmpty else { return false }
        return constantTimeEquals(supplied, token)
    }

    static func extractToken(headers: [String: String]) -> String {
        if let auth = headers["authorization"], auth.lowercased().hasPrefix("bearer ") {
            return String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        return headers["x-liberaro-token"]?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<aBytes.count { diff |= aBytes[i] ^ bBytes[i] }
        return diff == 0
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
