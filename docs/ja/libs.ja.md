🌐 [English](../libs.md) | [← README に戻る](../../README.ja.md)

# ネイティブ拡張

Zig でコンパイルされたオプショナルな gawk 拡張により、AWK ネイティブでは実現できない機能が利用できます。

| ライブラリ | 説明 |
|---|---|
| `libs/net` | Zig TCP イベントループ — keep-alive、SO_REUSEPORT マルチワーカー対応 |
| `libs/binary` | バイナリセーフなファイル I/O（PNG、JPG、WebP、フォントなど） |
| `libs/multipart` | `multipart/form-data` パーサー（ファイルアップロード対応） |
| `libs/crypto` | SHA-256 / HMAC-SHA256 |
| `libs/gzip` | Gzip / デフレート圧縮 |
| `libs/url` | 高性能な URL エンコード/デコード |
| `libs/cache` | [キャッシュ API](api.ja.md#キャッシュ-api-cache) の共有メモリバックエンド |

H-awk はライブラリなしで動作します。ライブラリが存在しない場合は正常に劣化します。例えば、`libs/net` がない場合は gawk ネイティブの `/inet/tcp/` トランスポートにフォールバックし、`libs/cache` がない場合はキャッシュ API が `file` または `memory` バックエンドにフォールバックします。

## マルチワーカー & Keep-Alive（`libs/net`）

`libs/net` がビルドされると、`bin/hawk` は N 個の独立した gawk ワーカーを生成し、`SO_REUSEPORT` 経由で同じポートを共有します。OS カーネルがワーカー間に着信接続を分配します。各ワーカーは監視され、クラッシュ時に自動再起動されます。

```sh
# CLI
./bin/hawk serve --workers 8 app.awk

# Make
make run WORKERS=8

# 環境変数
HAWK_WORKERS=8 ./bin/hawk app.awk
```

HTTP/1.1 keep-alive はデフォルトで有効です。ワーカーはアイドル接続を保持し、設定可能なタイムアウト後に閉じます：

```sh
HAWK_KEEPALIVE_TIMEOUT=30 ./bin/hawk app.awk   # 30s アイドルタイムアウト（デフォルト: 75）
```

| 変数 | デフォルト | 説明 |
|---|---|---|
| `HAWK_WORKERS` | `4` | ワーカープロセス数（`libs/net` が必要） |
| `HAWK_KEEPALIVE_TIMEOUT` | `75` | アイドル keep-alive タイムアウト（秒） |

## URL ヘルパー（`libs/url`）

機能: URL percent encode/decode、クエリ文字列の parse/build。

Fallback: `libs/url` がない場合も `core/url.awk` で動作します。

Build: `build-libs` ターゲットに含まれます。

環境変数: なし。

## JSON ヘルパー（`libs/json`）

機能: JSON encode/decode、型付き decode。

Fallback: `ctx.res.json` は AWK encoder にフォールバックします。`json.decode` には `libs/json` が必要です。

Build: `build-libs` ターゲットに含まれます。

環境変数: なし。

## gzip 圧縮（`libs/gzip`）

機能: HTTP レスポンスボディの gzip 圧縮。

Fallback: `libs/gzip` がない場合、gzip は無効化され安全な no-op になります。

Build: `build-libs` ターゲットに含まれます。

環境変数:

| 変数 | デフォルト | 説明 |
|---|---|---|
| `HAWK_GZIP` | 未設定 | `1` にすると gzip を有効化 |
| `HAWK_GZIP_MIN_SIZE` | `1024` | 圧縮する最小本文サイズ（バイト） |

## セットアップ

```sh
# すべてのライブラリをビルド（Zig 0.14+ が必要）
make build-libs

# またはプリコンパイル済みバイナリを取得（Zig は不要）
HAWK_REPO=<owner>/<repo> make fetch-libs
```

有効なライブラリはスタートアップ時に表示されます：

```text
[INFO]  H-awk listening on http://0.0.0.0:8080 [libs: net, binary]
```
