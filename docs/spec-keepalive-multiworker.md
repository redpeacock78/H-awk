# Spec: HTTP Keep-Alive + SO_REUSEPORT Multi-Worker

## 概要

- **Keep-Alive**: HTTP/1.1 デフォルト接続維持。アイドルタイムアウト sweep。
- **SO_REUSEPORT Multi-Worker**: libs/net ビルド済み時に N 個の gawk worker を起動。カーネルが接続を分散。

## 設定

| 環境変数 | デフォルト | 説明 |
|---|---|---|
| `HAWK_KEEPALIVE_TIMEOUT` | `75` | アイドル接続を閉じるまでの秒数 (Nginx 準拠) |
| `HAWK_WORKERS` | `4` | worker 数。libs/net 未使用時は強制 1 |

CLI: `bin/hawk --workers N app.awk`

## Phase 1: Keep-Alive

### libs/net/src/http_parser.zig

- `keep_alive` デフォルト変更: HTTP/1.1 → `true`、HTTP/1.0 → `false`
- `Connection:` ヘッダで上書き (keep-alive=true / close=false)
- `formatPollResult` フォーマット変更:
  ```
  conn_id \x1e method \x1e path \x1e headers_block \x1e body_len \x1e keep_alive \x1e body
  ```
  フィールド 6 (0-indexed: 7番目) に `keep_alive` (0 or 1) を追加。body の前に置くことで body 内の `\x1e` を安全に扱う。

### libs/net/src/conn_pool.zig

- `Conn` に `last_used: i64` フィールド追加 (初期値: `std.time.nanoTimestamp()`)

### libs/net/src/event_loop.zig

- `EventLoop` struct に `keepalive_timeout_ns: i64` 追加
- `init()`: `HAWK_KEEPALIVE_TIMEOUT` env 読み込み (デフォルト 75s)
- `drainResponses()`:
  - レスポンスバイト列から `Connection:` ヘッダをスキャン
  - keep-alive: fd を閉じず `conn.last_used` 更新
  - close: 従来通り fd クローズ & pool から削除
- `runKqueue` / `runEpoll`: kevent/epoll_wait timeout を 5s に変更
- ループ内で `sweepIdleConns()` 呼び出し:
  - `conn.keep_alive && now - conn.last_used > keepalive_timeout_ns` の接続を閉鎖

### core/request.awk — parse_request_zig

- フィールド数チェック: `n < 5` → `n < 6`
- `parts[6]` = keep_alive → `req["keep_alive"]`
- body join: `parts[7..n]` に変更

### core/http.awk

- `_hawk_serve()`: `HAWK_KEEPALIVE_TIMEOUT` 初期化 (env 優先、デフォルト 75)
- `_zig_http_send()`: `response_wire` 呼び出し前に接続ヘッダ設定:
  - `req["keep_alive"] == "1"` かつ `header:connection` 未設定:
    - `res["header:connection"] = "keep-alive"`
    - `res["header:keep-alive"] = "timeout=" HAWK_KEEPALIVE_TIMEOUT`
  - それ以外: `res["header:connection"] = "close"`
- `response_wire` の `Connection: close` フォールバックは /inet/tcp path 用に残す

## Phase 2: SO_REUSEPORT Multi-Worker

### libs/net/src/event_loop.zig — init()

`SO_REUSEADDR` の直後に追加:
```zig
const SO_REUSEPORT_VAL: u32 = if (builtin.os.tag == .macos) 0x0200 else 15;
_ = std.posix.system.setsockopt(listen_fd, std.posix.SOL.SOCKET, SO_REUSEPORT_VAL,
    @ptrCast(&reuse), @sizeOf(c_int));
```

### bin/hawk

変更点:
1. `#!/usr/bin/env bash`
2. bash 4.3+ チェック (`BASH_VERSINFO`)
3. `--workers N` / `HAWK_WORKERS` パース (デフォルト 4)
4. **libs/net 検出後に有効 worker 数を決定**:
   - `$LIBS_ARGS` に `libhawk_net` が含まれる → `EFFECTIVE_WORKERS=$WORKERS`
   - 含まれない → `EFFECTIVE_WORKERS=1`、workers > 1 なら警告
5. `WORKER_PIDS=()` で全 PID 管理
6. N 個の gawk を起動
7. supervisor ループ:
   - `wait -n` (bash 4.3+) で任意の子終了待ち
   - `kill -0` スキャンで死亡 PID 特定
   - 非 0 終了: 1s 後に再起動
8. `shutdown()`: 全 WORKER_PIDS に SIGTERM → wait → PID ファイル削除

## 変更ファイル

```
libs/net/src/event_loop.zig
libs/net/src/conn_pool.zig
libs/net/src/http_parser.zig
core/request.awk
core/http.awk
bin/hawk
```

## テスト追加

- `tests/e2e/`: keep-alive 接続再利用 (同一 fd で複数リクエスト)
- `tests/e2e/`: multi-worker 起動確認 (WORKERS=2、ps で 2 gawk 確認)
