import Foundation

/// QR コードにエンコードするペアリング情報。iOS 側は同じフィールド名の
/// `Codable` 構造体でデコードし、`macBackendLANURL` / `macBackendAuthToken` /
/// `irodoriMacBatchURL` / `irodoriMacBatchToken` (AppPreferenceKey) にそのまま書き込む。
///
/// この構造体の JSON 表現が iOS 側と Mac 側の唯一の契約点。フィールドを変える場合は
/// 両リポジトリを同時に更新すること。
struct PairingPayload: Codable, Equatable {
    /// スキーマバージョン。互換性が壊れる変更をする場合だけ上げる。
    var v: Int = 1
    var host: String
    var upscalePort: Int
    var upscaleToken: String
    var irodoriPort: Int
    var irodoriToken: String

    func encodedString() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let text = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(self, .init(codingPath: [], debugDescription: "utf8 encode failed"))
        }
        return text
    }
}
