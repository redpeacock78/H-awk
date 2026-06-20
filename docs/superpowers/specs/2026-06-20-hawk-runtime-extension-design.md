# H-awk ランタイム拡張設計仕様

## 目的と設計思想

H-awk に **Supervisor**、**擬似プロセスモデル**、**キャッシュバックエンド** の三つのランタイム層を追加する。

設計の基本方針は「素朴に動くが、環境が整うと強くなる」である。
Zig 拡張や Supervisor は強力なオプショナル層として扱い、H-awk コアの必須依存にはしない。
gawk と Bash のみの環境でも既存機能を損なわず、拡張が揃ったときに高速・堅牢になる。

内部実装として **Smalltalk ライクなメッセージングモデル** を core 内部 ABI として導入するが、
ユーザー向け DSL にはこれを露出させない。
`cache::get` / `cache::set` / `proc::call` / `proc::cast` のような通常のファサード API として提供し、
`selector`、`ObjectSpace`、`mailbox` といった低レベルの概念はコアの内部に隠蔽する。

## 全体アーキテクチャ

```
app.awk
  ↓
public facade API
  cache::get / cache::set / cache::remember
  proc::call / proc::cast
  ↓
core internal runtime
  core/cache.awk
  core/message.awk
  core/objectspace.awk
  core/mailbox.awk
  core/proc.awk
  ↓
transport
  FIFO / file / pipe
  (将来) Unix domain socket / shared ring buffer
  ↓
supervised actor / worker process
  ↓
cache backend
  Zig shared cache (libs/cache)
  file cache ($HAWK_RUN_DIR/cache/)
  memory cache (AWK array)
```

## コアモジュールのロード方針

新規コアモジュールはすべて `hawk.awk` に `@include` を追加して常時ロードする。
Supervisor が起動していない状態でも `cache::get` を呼び出せるようにするためである。
各モジュールは起動時に環境を検出し、利用可能な機能だけを有効化する。

`hawk.awk` の include 順序:

```awk
@include "core/util.awk"
-- 既存モジュール群 --
@include "core/cache.awk"       # 新規（util の後、http の前）
@include "core/message.awk"     # 新規
@include "core/objectspace.awk" # 新規
@include "core/mailbox.awk"     # 新規
@include "core/proc.awk"        # 新規
@include "core/http.awk"        # 既存（最後に維持）
```

## パブリック API

### cache API

```awk
cache::get(key)                    # 値を返す。miss は空文字列
cache::set(key, value, ttl_sec)    # TTL 秒でキャッシュ
cache::del(key)                    # 削除
cache::has(key)                    # 存在確認（TTL 考慮）
cache::remember(key, ttl, fn)      # miss 時に fn を呼び set して返す
cache::stats()                     # バックエンド統計
cache::backend()                   # 現在のバックエンド名を返す
```

`cache::get` は空文字列との区別が必要なケースに備え、補助関数を用意する。

```awk
cache::found()      # 直前の cache::get がヒットしたか（0/1）
cache::last_error() # 直前の操作のエラーメッセージ
```

将来的には Option / Result と統合する方向で設計する。

### proc API

```awk
proc::self()                        # 自身の proc ID を返す
proc::register(name, pid)           # logical name と pid を登録
proc::whereis(name)                 # name から pid を解決
proc::cast(name_or_pid, message)    # fire-and-forget 送信
proc::call(name_or_pid, msg, timeout_ms)  # 返信を待つ同期呼び出し
```

`proc::spawn` は初期実装では未実装とし、Supervisor が起動した actor/worker に対する
`cast` / `call` を優先する。

## 内部メッセージモデル

コア内部の通信は **メッセージエンベロープ** として統一する。

エンベロープのフィールド:

- `to`: 送信先 proc URL（例: `proc://cache/global`）
- `from`: 送信元 proc URL
- `ref`: メッセージの一意識別子
- `kind`: `call` / `cast` / `reply` / `error`
- `selector`: Smalltalk 由来のメッセージセレクタ（例: `at:`、`at:put:ttl:`）
- `args`: 引数リスト
- `reply_to`: reply FIFO のパス（call 時のみ）
- `timeout_ms`: タイムアウトミリ秒
- `trace_id`: リクエスト追跡用 ID

エンコード形式は JSON に固執しない。
既存の H-awk ADT エンコード方針（TSV / Unit Separator）と整合するか、
tab/newline を含む値を安全に扱える escape/unescape を伴う形式を採用する。

ファサードから内部への変換例:

```
cache::get(key)            → objectspace::call("cache", "at:", key)
cache::set(key, value, ttl) → objectspace::cast("cache", "at:put:ttl:", key, value, ttl)
```

未定義セレクタは `doesNotUnderstand:` に落とせる構造にする。
ただし初期実装では `doesNotUnderstand:` は error ログにとどめる。

## core/message.awk

**責務**: メッセージエンベロープの生成、ref 生成、encode/decode、kind 判定、reply エンベロープ生成。

```awk
message::make_call(to, from, selector, args, reply_to, timeout_ms)
message::make_cast(to, from, selector, args)
message::make_reply(to, from, ref, payload)
message::make_error(to, from, ref, error_type, message)
message::ref()
message::encode(...)
message::decode(line, out)
```

## core/objectspace.awk

**責務**: logical name から proc ID への解決、actor/service の登録、alias 管理、メッセージ層への call/cast 委譲。

**パブリック**: なし（コア内部 API）。

初期実装の registry は `$HAWK_RUN_DIR/registry.tsv`。
Supervisor を使わない場合はプロセスローカルの AWK 配列にフォールバックする。

**registry の安全契約**:

`registry.tsv` は複数プロセスが同時に読み書きするため、以下のルールを仕様として定める。

- **更新はロック付き atomic write のみ**: tmp file に書き込んでから `mv` で置換する。
  ロックには file backend と同様の `mkdir` ロックを使う（`$HAWK_RUN_DIR/registry.lock.d/`）。
- **エントリには所有者 PID・起動時刻・登録トークンを記録する**:
  `name<TAB>object_id<TAB>owner_pid<TAB>started_at<TAB>reg_token` の形式で保存する。
  `reg_token` は各プロセスの起動時に生成するランダム文字列（例: `$RANDOM$RANDOM`）。
  Supervisor は `$HAWK_RUN_DIR/pids/$pid.token` にも同じトークンを書き込む。
- **`resolve` はトークンで同一性を検証する**: `kill -0 $owner_pid` の成功だけではなく、
  `$HAWK_RUN_DIR/pids/$pid.token` の内容が registry の `reg_token` と一致するかを確認する。
  OS による PID 再利用後は元のトークンファイルが Supervisor によって削除されているため、
  一致しなくなり stale エントリとして miss 扱いになる。
- **Supervisor はクラッシュした actor/worker の名前を unregister する**: restart 前に
  `$HAWK_RUN_DIR/pids/$old_pid.token` を削除し、古いエントリを registry から除去する。
  新しい PID と新しいトークンで再登録する。これにより stale エントリが蓄積しない。
- **registry が破損した場合の挙動**: resolve が失敗したとき、呼び出し元は `UnknownProcess` エラーを受け取る。
  Supervisor が存在しないスタンドアロン実行では AWK 配列のみを使い、`registry.tsv` は作成しない。

```awk
objectspace::register(name, object_id)
objectspace::resolve(name)
objectspace::call(name, selector, args, timeout_ms)
objectspace::cast(name, selector, args)
objectspace::unregister(name)
```

## core/mailbox.awk

**責務**: FIFO/file によるメッセージトランスポート、send、request/reply、タイムアウト、mailbox パス解決。

```awk
mailbox::path(pid)
mailbox::send(pid, encoded_message)
mailbox::call(pid, encoded_message, timeout_ms)
mailbox::reply(reply_to, encoded_message)
mailbox::ensure(pid)
```

トランスポートパス:

```
$HAWK_RUN_DIR/mailbox/<pid>.fifo
$HAWK_RUN_DIR/reply/<ref>.fifo
```

blocking read のタイムアウトは AWK 単体での実装が困難なため、Bash helper に移譲してよい。
`cast` は fire-and-forget。`call` は必ずタイムアウトを持つ。
mailbox への書き込み失敗は `ProcessDown` 相当のエラーとして扱う。

## core/proc.awk

**責務**: proc ファサード、logical proc ID 管理、supervisor との境界、proc call/cast。

内部で `objectspace`、`message`、`mailbox` を使う。

`proc::call` のエラー種別:

- `Timeout`
- `ProcessDown`
- `MailboxError`
- `UnknownProcess`
- `DecodeError`

## キャッシュバックエンド

### バックエンド選択

`HAWK_CACHE_BACKEND` 環境変数でバックエンドを制御する。

- **`auto`**: `zig` → `file` → `memory` の順で自動選択
- **`zig`**: Zig 拡張必須。使用不可の場合は起動エラー
- **`file`**: AWK/Bash のみで動作する file-backed cache
- **`memory`**: プロセスローカルな AWK 配列 cache
- **`off`**: cache 無効（get は miss、set は no-op）

`HAWK_RUN_DIR` のデフォルト値と作成ルール:

明示的に `HAWK_RUN_DIR` が指定されていない場合、`hawk-supervise` が安全なランタイムディレクトリを作成する。
パスの予測可能性によるハイジャックを防ぐため、以下のルールに従う。

```bash
# hawk-supervise が起動時に実行する run dir セットアップ
_setup_run_dir() {
  if [[ -z "${HAWK_RUN_DIR:-}" ]]; then
    # UID + nonce でパス予測を困難にする
    HAWK_RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hawk-run-$(id -u)-XXXXXX")"
  else
    # 既存パスの安全性を検証する
    if [[ -L "$HAWK_RUN_DIR" ]]; then
      echo "[hawk] HAWK_RUN_DIR is a symlink: $HAWK_RUN_DIR" >&2; exit 1
    fi
    if [[ ! -d "$HAWK_RUN_DIR" ]]; then
      mkdir -p "$HAWK_RUN_DIR"
    fi
    # オーナーが自分自身であることを確認する
    local owner
    owner="$(stat -c '%u' "$HAWK_RUN_DIR" 2>/dev/null || stat -f '%u' "$HAWK_RUN_DIR")"
    if [[ "$owner" != "$(id -u)" ]]; then
      echo "[hawk] HAWK_RUN_DIR not owned by current user: $HAWK_RUN_DIR" >&2; exit 1
    fi
  fi
  chmod 0700 "$HAWK_RUN_DIR"
  export HAWK_RUN_DIR
}
```

supervisor を使わず `HAWK_CACHE_BACKEND=file` を直接使うケース（スタンドアロン実行）では、
`cache::_detect_backend()` が同様の安全チェックを実行し、問題があれば `memory` にフォールバックする。

`cache::_detect_backend()` が `$HAWK_RUN_DIR/cache/` への書き込み可否を確認し、
可能なら `file`、不可なら `memory` にフォールバックする。

### memory backend

AWK 配列によるプロセスローカルなキャッシュ。

```awk
_cache_value[key]
_cache_expires[key]  # epoch 秒
```

- worker 間の共有なし
- `$HAWK_RUN_DIR` が不要
- unit test で最も使いやすい

### file backend

AWK/Bash のみで動作する file-backed cache。

保存先: `$HAWK_RUN_DIR/cache/cache.tsv`

保存形式:

```
key_hash<TAB>expires_at<TAB>escaped_key<TAB>escaped_value
```

仕様:

- `mkdir` ロックで排他制御（`flock` は環境差があるため初期実装では不使用）
- `set` は tmp file に書いてから atomic `mv`
- `get` は期限切れエントリを miss 扱い
- 期限切れエントリの掃除は opportunistic（get 時に発見した場合のみ）
- value に tab/newline が入るため escape/unescape 必須
- 性能より正しさを優先する fallback として位置づける

ロック方針: `mkdir "$lockdir"` 成功でロック取得、`rmdir "$lockdir"` で解放。

ステールロック対応（初期実装で必須）: ロック取得をリトライ上限付きで行う（例: 50ms × 20回 = 最大 1秒）。
タイムアウト時は `CacheLockTimeout` エラーを返す。
ロックディレクトリ内に所有者 PID を記録し（`$lockdir/owner_pid`）、再試行時に `kill -0 $owner_pid`
が失敗していればロックを奪取して `rmdir` する。この動作は registry ロック（`$HAWK_RUN_DIR/registry.lock.d/`）
にも同様に適用する。

### Zig cache backend

`libs/cache` として実装する。`libs/net` と同一のパターンを踏襲する。

初期実装は固定長スロットハッシュテーブル:

```zig
const Entry = extern struct {
    hash: u64,
    key_len: u32,
    val_len: u32,
    expires_at: i64,
    flags: u32,
    key: [128]u8,
    val: [2048]u8,
};
```

初期制限:

- key: 128 bytes 以内
- value: 2048 bytes 以内
- slot 数: 4096
- collision 解決: open addressing
- TTL 判定: `get` 時に期限切れ確認

将来的に可変長 arena / ring buffer / larger mmap に移行可能な構造にする。

`hawk-libs` の `libs` サブコマンドが `HAWK_LIBS_cache=1` をセットし、
`cache::_detect_backend()` がこれを参照して Zig backend を候補にする。

AWK 側から呼び出す関数:

```
hawk_cache_get(key)
hawk_cache_set(key, value, ttl)
hawk_cache_del(key)
hawk_cache_has(key)
hawk_cache_stats()
```

## core/cache.awk

**責務**: パブリックキャッシュファサード、バックエンド検出と委譲、memory/file/Zig 各 backend 実装、`remember` ヘルパー、統計。

内部関数:

```awk
cache::_detect_backend()
cache::_get_zig(key)  / cache::_set_zig(key, value, ttl)
cache::_get_file(key) / cache::_set_file(key, value, ttl)
cache::_get_memory(key) / cache::_set_memory(key, value, ttl)
```

## Bash Supervisor

### libexec/hawk-supervise

既存の `hawk-serve` は `wait -n` + worker 再起動ループを持っているが、
`hawk-supervise` はこれを抽出・強化したものとして実装する。

**責務**:

- desugar/build 済みアーティファクトを worker に渡す
- N 個の worker と actor プロセスを起動する
- pid / role / restart count / started_at を管理する
- `wait -n` で worker/actor の終了を検知する
- restart strategy に基づいて再起動する
- restart intensity 超過時に全体を停止する
- SIGTERM / SIGINT で子プロセスをまとめて終了する
- `$HAWK_RUN_DIR` のディレクトリ構造を準備する

`$HAWK_RUN_DIR` 構成:

```
$HAWK_RUN_DIR/
  pids/
  mailbox/
  reply/
  log/
  cache/
  registry.tsv
```

worker 起動時の環境変数:

```bash
HAWK_SUPERVISED=1
HAWK_RUN_DIR=<path>
HAWK_WORKER_ID=<n>
HAWK_PROC_ID=web:<n>
```

actor 起動時の環境変数:

```bash
HAWK_SUPERVISED=1
HAWK_RUN_DIR=<path>
HAWK_PROC_ID=actor:<name>
HAWK_ACTOR_NAME=<name>
```

**restart strategy**: 初期実装は `permanent`（常に再起動）のみ。
将来的に `transient`（異常終了のみ）、`temporary`（再起動しない）を追加する。

**restart intensity**: 短時間に繰り返し死ぬ worker を再起動し続けないための閾値。

```bash
HAWK_RESTART_MAX="${HAWK_RESTART_MAX:-5}"
HAWK_RESTART_WINDOW="${HAWK_RESTART_WINDOW:-10}"
```

`HAWK_RESTART_WINDOW` 秒以内に `HAWK_RESTART_MAX` 回以上死んだ場合、supervisor 全体を停止する。

`hawk-serve` との関係: `--workers 1` では従来通り `hawk-serve` が直接 worker を実行する。
`--workers N`（N > 1）かつ Supervisor モードが有効な場合、`hawk-serve` が `hawk-supervise` に委譲する。

### libexec/hawk-worker

supervisor 配下の worker 実行を担う薄いラッパー。

**責務**:

- 環境変数を整える
- mailbox を `ensure` する
- 既存の serve 実行パスに渡す

## 既存コードへの影響

`hawk-serve` の変更は最小限にとどめる。
既存の `wait -n` ループは Supervisor モード時に `hawk-supervise` への委譲に置き換えられるが、
`--workers 1` での動作は変更しない。

既存テストはすべて維持する。
新規モジュールの追加によって既存の `test-unit` / `test-e2e` が壊れないことを各フェーズで確認する。

## 実装フェーズとスコープ

### Phase 1: cache facade + memory backend
- `core/cache.awk` 追加
- `cache::get/set/del/has/backend/found` を実装
- `HAWK_CACHE_BACKEND=memory` 対応
- `tests/unit/test_cache.awk` と `tests/unit/run.awk` への追加

### Phase 2: file backend
- file-backed cache の実装（escape/unescape、mkdir ロック、atomic write）
- `HAWK_CACHE_BACKEND=file` 対応
- `HAWK_RUN_DIR` デフォルト値の確立

### Phase 3: backend auto detect
- `HAWK_CACHE_BACKEND=auto` と `off` の実装
- `zig → file → memory` フォールバック
- `cache::backend()` の実装

### Phase 4: supervisor skeleton
- `libexec/hawk-supervise` 追加
- `libexec/hawk-worker` 追加
- `--workers N` 時の supervisor 委譲
- restart intensity 実装
- SIGTERM / SIGINT cleanup
- `$HAWK_RUN_DIR` のセットアップ

### Phase 5: message / objectspace / mailbox skeleton
- `core/message.awk` / `core/objectspace.awk` / `core/mailbox.awk` 追加
- message encode/decode、registry、FIFO mailbox
- `cast` を先行実装

### Phase 6: proc facade
- `core/proc.awk` 追加
- `proc::self / register / whereis / cast`
- `proc::call` のタイムアウト方針を実装または明記

### Phase 7: Zig cache backend
- `libs/cache/` 追加（build.zig、固定長スロットハッシュテーブル）
- AWK ラッパーとの接続
- `HAWK_LIBS_cache=1` 時の backend candidate 登録

## テスト計画

### Unit tests（`tests/unit/`）

- `test_cache.awk`: memory get/set、TTL、file escape/unescape、backend detect
- `test_message.awk`: make_call、make_cast、encode/decode、selector 保存
- `test_objectspace.awk`: register、resolve、unknown name
- `test_proc.awk`: self、whereis

### E2E tests（`tests/e2e/`）

- `supervisor_restart.sh`: 2 worker 起動、1 worker kill、後継 worker 起動確認
- `cache_file_backend.sh`: 1 プロセスで set、別プロセスで get
- `cache_shared_between_workers.sh`: マルチワーカーでキャッシュ共有確認
- `proc_mailbox.sh`: actor 起動、cast 送信、actor 受信確認

### Zig tests（`libs/cache/tests/`）

- `cache_test.zig`: set/get、del、TTL 期限切れ、collision、stats

## 実装制約

- 既存の `libexec` 分離方針に従う
- `hawk-serve` を肥大化させない
- Zig 拡張は optional として実装し、Zig 不在の環境で既存機能を壊さない
- パブリック API をバックエンドに依存させない
- file fallback は性能より正しさを優先する
- タイムアウトのない blocking call を作らない
- `selector` / `ObjectSpace` / `mailbox` は原則としてコア内部に隠蔽する
- 既存テストを壊さない

## 対象外（Non-goals）

- 本物の BEAM VM 実装
- green thread / lightweight process 実装
- 完全な Smalltalk オブジェクトシステム
- パブリック DSL としての `cache ! at("k") put("v")` 構文追加
- 分散ノード通信 / network-transparent actor
- 高度なスケジューラ
- production-grade ロックフリー共有メモリ
- 外部 DB 依存キャッシュ（Valkey / libSQL など）

## 推奨 PR 分割

| PR | タイトル | 内容 |
|----|----------|------|
| 1 | `feat(cache): add backend-independent cache facade` | core/cache.awk、memory/file backend、auto detect、tests |
| 2 | `feat(supervisor): add wait-n worker supervisor` | hawk-supervise、hawk-worker、restart intensity、e2e |
| 3 | `feat(runtime): add internal message and proc skeleton` | message/objectspace/mailbox/proc.awk、tests |
| 4 | `feat(cache): add optional zig shared cache backend` | libs/cache、Zig build、AWK wrapper、integration |
