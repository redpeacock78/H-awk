🌐 [English](libs.md) | [← README に戻る](../README.ja.md)

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

H-awk はライブラリなしで動作します。ライブラリが存在しない場合は正常に劣化します。例えば、`libs/net` がない場合、サーバーは gawk のネイティブな `/inet/tcp/` トランスポートにフォールバックします。

## キャッシュ API

H-awk は自動バックエンド選択機能付きの組み込みキャッシュファサードを提供します。AWK ファイルで dot-notation を使用してください：

```awk
function todo_list_html() -> Response {
  let cached: Str = cache.get("todos:html")
  if (cache.found()) {
    return ctx.res.html(safe.html.raw(cached))
  }
  # ... build response ...
  cache.set("todos:html", out, 30)   # TTL: 30 seconds
  return ctx.res.html(safe.html.raw(out))
}

function todo_add() -> Response {
  # ... write data ...
  cache.del("todos:html")   # invalidate on write
  cache.del("todos:json")
}
```

### キャッシュ API リファレンス

| DSL | 戻り値の型 | 説明 |
|---|---|---|
| `cache.get(key)` | `Str` | キャッシュされた値を取得します。キャッシュヒットと空文字列を区別するには `cache.found()` をチェックしてください。 |
| `cache.set(key, value, ttl)` | `Void` | TTL 付きで値を保存します。`ttl=0` は無期限を意味します。 |
| `cache.del(key)` | `Void` | キーを削除します。キーが存在しない場合は何もしません。 |
| `cache.has(key)` | `Bool` | キーが存在し、有効期限が切れていない場合は 1 を返します。 |
| `cache.found()` | `Bool` | 最後の `cache.get` がヒットした場合は 1 を返します。 |
| `cache.remember(key, ttl, fn)` | `Str` | キャッシュから取得、またはミス時にコンピュート：`fn()` をミス時に呼び出し、結果をキャッシュして返します。 |
| `cache.backend()` | `Str` | アクティブなバックエンド名（`zig`、`file`、`memory`、または `off`）を返します。 |
| `cache.stats()` | `Str` | ヒット/ミス/セットカウンタを文字列で返します。 |

### バックエンド選択

`HAWK_CACHE_BACKEND` を明示的に設定するか、未設定のままにして自動選択を行ってください：

| 値 | 説明 |
|---|---|
| `auto`（デフォルト） | `zig` → `file` → `memory`、最初に利用可能なものを使用 |
| `zig` | `libs/cache` 経由の共有メモリキャッシュ（`make build-libs` が必要）。すべてのワーカー間で共有されます。 |
| `file` | `$HAWK_RUN_DIR/cache/cache.tsv` のファイルバックアップキャッシュ。ワーカー間で共有されます。Zig は不要です。 |
| `memory` | プロセスローカルな AWK 配列。ワーカー間では共有されません。 |
| `off` | キャッシュ無効化。`cache.get` は常にミスし、`cache.set` は何もしません。 |

`libs/cache` がビルドされている場合、`zig` バックエンドが自動的に使用され、すべてのワーカーが同じキャッシュを共有します。それ以外の場合は、`HAWK_RUN_DIR` が書き込み可能であれば `file` が使用され、そうでなければ `memory` が使用されます。

```sh
# 明示的なバックエンド指定
HAWK_CACHE_BACKEND=file ./bin/hawk app.awk

# キャッシュを無効化
HAWK_CACHE_BACKEND=off ./bin/hawk app.awk
```

## マルチワーカー & Keep-Alive（`libs/net`）

`libs/net` がビルドされると、`bin/hawk` は N 個の独立した gawk ワーカーを生成し、`SO_REUSEPORT` 経由で同じポートを共有します。OS カーネルはワーカー間に着信接続を分配します。各ワーカーは監視され、クラッシュ時に自動再起動されます。

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
HAWK_KEEPALIVE_TIMEOUT=30 ./bin/hawk app.awk   # 30s idle timeout (default: 75)
```

| 変数 | デフォルト | 説明 |
|---|---|---|
| `HAWK_WORKERS` | `4` | ワーカープロセス数（`libs/net` が必要） |
| `HAWK_KEEPALIVE_TIMEOUT` | `75` | アイドル keep-alive タイムアウト（秒） |

## セットアップ

```sh
# すべてのライブラリをビルド（Zig 0.14+ が必要）
make build-libs

# またはプリコンパイル済みバイナリを取得（Zig は不要）
HAWK_REPO=<owner>/<repo> make fetch-libs
```

有効なライブラリはスタートアップ時に表示されます：

```
[INFO]  H-awk listening on http://0.0.0.0:8080 [libs: net, binary]
```
