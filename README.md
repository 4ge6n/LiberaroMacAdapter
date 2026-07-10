# LiberaroMacAdapter

[Liberaro-iOS](https://github.com/4ge6n/Liberaro-iOS) の Mac サイドカー
(`mac-sidecar/upscale`, `mac-sidecar/irodori-tts`) を GUI で束ねるための
ネイティブ macOS アプリ。[LiberaroQueueMac](../Liberaro-iOS/LiberaroQueueMac) の
雛形を土台に、実際にキューを受け取って処理するところまで実装したもの。

## アーキテクチャ（ハイブリッド）

- **Upscale**: `mac-sidecar/upscale/liberaro_upscale_server.py` と**同一のワイヤープロトコル**
  (`GET /health` `/models` `/jobs` `/progress`, `POST /jobs`, `GET /jobs/{id}` `/jobs/{id}/result`,
  `DELETE /jobs/{id}`、Bearer token 認証) を Swift でネイティブ再実装。iOS 側
  (`MacUpscaleClient`) は無改修でこのアプリに接続できる。HTTP サーバーは
  `Network.framework` (`NWListener`) だけで書いた自前の最小実装（外部依存ゼロ）。
  ジョブは `~/.liberaro/<engine>/` の ncnn-vulkan バイナリへ subprocess で委譲する
  （`install_ncnn_vulkan.command` でインストールしたものをそのまま使う）。
- **Irodori TTS**: 既存の `irodori_batch_server.py`（stdlib のみ、アプリに同梱）を
  そのまま subprocess として起動/停止/監視する。ローカルの Gradio (Irodori) との
  橋渡しプロトコル自体は書き直していない（未検証環境で書き直すと動作未確認のまま
  壊れるリスクが高いため、既存の動作実績があるコードをそのまま使う判断）。

## QR ペアリング

「ペアリング」タブに、LAN アドレス・両サービスのポート・認証トークンを
JSON エンコードした QR コードを表示する。iOS 側 (`Liberaro-iOS/Features/Settings/MacPairingScanView.swift`,
AVFoundation ベースのスキャナ) でこれを読み取ると、`macBackendLANURL` /
`macBackendAuthToken` / `irodoriMacBatchURL` / `irodoriMacBatchToken` の
4 つの設定値が一度のスキャンで自動入力される（読み取り導線は「実行先」設定と
「TTS サーバー設定」の両方に用意）。ペイロード形式は
[`Sources/Pairing/PairingPayload.swift`](Sources/Pairing/PairingPayload.swift) 参照。
iOS 側の対応 struct と JSON round-trip の契約はスタンドアロンテストで検証済み
（フィールド名・型を変える場合は両リポジトリを同時に更新すること）。

## 開発

```bash
xcodegen generate   # project.yml から .xcodeproj を再生成（ファイル追加後は必須）
open LiberaroMacAdapter.xcodeproj
```

App Sandbox は無効（ncnn-vulkan の未署名バイナリと `/usr/bin/python3` subprocess を
直接起動する用途と根本的に相性が悪いため）。既存の `.command` / `.py` と同じ、
署名は Automatic (Development team) のローカル実行が前提。

## 既知の制約 / 今後の課題

- Irodori TTS 側はダッシュボードに構造化ジョブ一覧を出せない（既存 Python サーバに
  ジョブ一覧 API が無いため）。現状はプロセスの起動/停止状態と生ログの tail のみ。
- HTTP サーバーは keep-alive 非対応（毎リクエスト `Connection: close`）。Python 版も
  実質同等の挙動なので互換性上の問題は無いが、大量ページの一括投入では TCP
  ハンドシェイクが都度発生する。
