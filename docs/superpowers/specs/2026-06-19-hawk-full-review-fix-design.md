# H-awk Full Review Fix 設計仕様

## 概要

本仕様は、H-awk リポジトリのコードレビューで発見された、優先度の高い不整合とランタイム上の危険性を修正する作業を定義する。
広範なリライトは行わず、小さく検証可能な変更を積み重ねる方針をとる。
ただし P0-3（TSV ロック）、P1-2（`ctx.res.json` セマンティクス変更）は破壊的変更を含む。
いずれも既存コードの誤りを修正するものであり、互換維持より正しい動作を優先する。

対象となるリポジトリの構成は以下のとおりである。

- `bin/hawk` および `libexec/hawk-*` による CLI 層
- `dsl/desugar.awk` を中心とする DSL-to-AWK コンパイラ
- 型付き DSL シグネチャと型チェック
- `Result` / `Option` ADT ランタイム
- safe HTML ブランディング
- gawk HTTP ランタイム
- オプションの Zig ネイティブライブラリ（`libs/net`）

---

## Phase 0: ベースライン検証

コードを変更する前に、現在のテストスイートを実行して既存の失敗を記録する。
新たな回帰と既存の失敗を混同しないようにするためである。

実行コマンドは以下のとおりである。

```sh
make lint
make test-dsl
make test-unit
make test-e2e
make ci
zig version || true
```

Zig 0.16.0 が利用可能な場合は、追加で以下を実行する。

```sh
make test-libs
make ci-full
```

---

## Phase 1: P0 Critical Fixes

### P0-1: `libs/net` リクエスト完全受信の保証

#### 問題

`libs/net/src/event_loop.zig` は、接続バッファに `\r\n\r\n` が存在した時点でリクエストを完了とみなす。
POST / PUT リクエストではリクエストボディが後続の TCP パケットで到着することがあるため、この実装は不完全なリクエストをエンキューする危険性がある。

#### 要求仕様

`http_parser.zig` に `ParseFrameResult` 構造体を追加し、フレーミング判定を一箇所に集約する。
`ParseFrameResult` は以下のフィールドを持つ。

```zig
const ParseFrameResult = struct {
    action: enum { enqueue, wait, error_response },
    // action == enqueue のとき: バッファから取り除くバイト数（ヘッダー + ボディ）
    // action == wait のとき: 0（バッファを変更しない）
    // action == error_response のとき: バッファから取り除くバイト数
    consume_len: usize,
    // action == error_response のときのみ有効
    status_code: u16,  // 400, 413, 501 など
    reason: []const u8,
    // true のときはレスポンス送信後に接続を閉じる
    should_close: bool,
};
```

`action` の種別と `consume_len`・`should_close` の関係は以下のとおりである。

| action | consume_len | should_close |
|---|---|---|
| `enqueue` | ヘッダー + ボディのバイト数 | `false` |
| `wait` | `0`（バッファ変更なし） | `false` |
| `error_response` | ヘッダーのバイト数（バッファに残ったボディバイトが次リクエストとして誤解釈されることを防ぐため、`should_close` は常に `true`） | 常に `true` |

`action == close` は廃止し、代わりに `action: error_response, should_close: true` を使う。
`action == error_response` を使う場合は `should_close` を常に `true` に設定する。`should_close = false` の `error_response` は存在しない。
フレーミングエラー（`Content-Length` 不正、`Transfer-Encoding` 非対応）はすべて `should_close: true` を設定してレスポンス送信後に接続を閉じる。
これにより、バッファに残留したボディバイトが次のリクエストとして誤解釈されることを防ぐ。

`event_loop.zig` は `consume_len` バイトだけバッファから取り除き、残余バイトはそのまま保持する（`should_close = true` の場合を除く）。
`action == error_response` かつ `should_close == true` の場合はレスポンス送信後に接続を閉じる。

**タイムアウトと DoS 防御:**
不完全なボディを待機する接続に対するアプリケーションレベルの read timeout は本フェーズの実装スコープ外とする。ただし、以下の制限がスロー送信による DoS を部分的に緩和する。

- `MAX_HEADER_SIZE`（8 KiB）を超えるヘッダー送信は `431` で即時切断する。
- `MAX_BODY_SIZE`（1 MiB）を超える `Content-Length` は `413` で即時切断する。
- アクティブな読み取りを行わないアイドル接続は `event_loop.zig` の既存 keep-alive idle sweep で処理される（この sweep が不完全ボディ待ち接続をカバーすることを実装時に確認する。カバーしない場合は別途 read timeout フラグを実装する）。

将来的には `event_loop.zig` に設定可能な per-connection read timeout を追加することで根本的に対応する（本仕様には含まない）。

リクエストが完了したとみなす条件は以下の 3 つをすべて満たすこととする。

1. ヘッダー終端子 `\r\n\r\n` がバッファに存在する。
2. `Content-Length` の有無を確定済みである（存在すること、または存在しないことが確認されていること）。
3. バッファが `header_end + 4 + content_length` バイト以上のデータを保持している。

`Content-Length` が存在しないリクエストは、ボディ長を 0 として扱う（`action: enqueue`）。
`Content-Length` の値が数値として解析できない場合は `400 Bad Request` を返す（`action: error_response, should_close: true`）。
`Content-Length` が負の値または `+` や空白プレフィックスを含む場合も `400 Bad Request` を返す（`action: error_response, should_close: true`）。
同一リクエストに `Content-Length` が複数存在する場合、または値が相互に矛盾する場合も `400 Bad Request` を返す（`action: error_response, should_close: true`）。
`Content-Length` が最大ボディサイズ（デフォルト 1 MiB = 1048576 バイト）を超える場合は `413 Payload Too Large` を返す（`action: error_response, should_close: true`）。
フレーミングエラーはすべて `should_close: true` を設定する。バッファに残留したボディバイトが次のリクエストとして誤解釈されることを防ぐためである。

最大ボディサイズはコンパイル時定数 `MAX_BODY_SIZE` として `http_parser.zig` に定義し、`event_loop.zig` はこれをインポートして使用する。フレーミング判定ロジックを持つパーサーが上限値も所有することで、Zig ネイティブランタイム内での参照元を一箇所に集約する。

`\r\n\r\n` が到達する前にバッファが `MAX_HEADER_SIZE`（デフォルト 8 KiB = 8192 バイト）を超えた場合は `431 Request Header Fields Too Large` を返す（`action: error_response, should_close: true`）。
`MAX_HEADER_SIZE` も `http_parser.zig` に定義する。

**AWK フォールバックランタイムとの関係:**
`core/http.awk` は既に `HAWK_MAX_HEADER_SIZE` と `HAWK_MAX_BODY_SIZE` 環境変数でこれらの上限を設定している。Zig ネイティブランタイムと AWK フォールバックランタイムはそれぞれ独立した実装であり、ポリシーソースも別である（Zig はコンパイル時定数、AWK は実行時環境変数）。この 2 者は並行して存在し、互いに干渉しない。デフォルト値（8 KiB ヘッダー、1 MiB ボディ）は両ランタイムで一致させること。

ヘッダー名の比較はすべて case-insensitive（`content-length`, `Content-Length`, `CONTENT-LENGTH` を同一視）で行う。
ヘッダー値の前後の OWS（optional whitespace）は RFC 7230 に従いトリムする。

`Transfer-Encoding` ヘッダーが存在する場合の動作は以下のとおりである。

- 任意の `Transfer-Encoding` 値（chunked、gzip、複数値・カンマ区切りを含む）：`action: error_response, status_code: 501, reason: "Not Implemented", should_close: true` を返す。

`Transfer-Encoding` と `Content-Length` が同時に存在する場合、RFC 7230 §3.3.3 に従い `Content-Length` を無視して `Transfer-Encoding` を優先し、上記の規則を適用する。

Keep-alive に対応するため、1 バッファに複数の完全なリクエストが含まれる場合は以下の処理とする。
`event_loop.zig` はソケット read ごとにバッファを使い果たすまで、内部ドレインループを実行する。

```
loop {
    result = parseFrame(buf)
    if result.action == .enqueue {
        enqueue(request)
        buf.consume(result.consume_len)
        // バッファにデータが残っていれば continue でループを継続する
        if buf.len == 0 { break }
    } else if result.action == .wait {
        break  // 完全なリクエストがないため次の read まで待機する
    } else {  // error_response
        sendSimpleError(result.status_code, result.reason)
        connection.close()
        break
    }
}
```

次の read イベントを待たずに、バッファ内の完全なフレームをすべて処理することで、バッファ済みリクエストが孤立する問題を防ぐ。

**エラーレスポンスの wire format:**

`action: error_response` の場合、`event_loop.zig` は以下の HTTP レスポンスを送信する関数 `sendSimpleError(conn, status_code, reason, close)` を実装する。

```
HTTP/1.1 {status_code} {reason}\r\n
Content-Type: text/plain; charset=utf-8\r\n
Content-Length: {len}\r\n
Connection: close\r\n
\r\n
{status_code} {reason}\r\n
```

`error_response` は常に `should_close = true` であるため、送信後に接続を閉じる。
バッファクリーンアップは `consume_len` バイト消費 + 接続クローズで行う（残余バイトを保持しない）。
`sendSimpleError` は常に `Connection: close` ヘッダーを出力する。これは `error_response` が常に `should_close = true` であることと一致する。

#### 変更対象ファイル

- `libs/net/src/event_loop.zig`
- `libs/net/src/http_parser.zig`
- `libs/net/tests/net_test.zig`

#### 追加するテスト

ヘッダーを先に送信し、ボディを後から送信するシナリオで、以下をすべて検証するテストを追加する。

- ボディ全体が到着する前にリクエストがエンキューされないこと。
- ボディ全体が到着した後にリクエストが正しくエンキューされること。
- ボディの内容が完全に保持されていること。
- `Transfer-Encoding: chunked` リクエストに対して `501` を返し、接続を閉じること。
- `Transfer-Encoding: gzip, chunked`（複数値）に対して `501` を返し、接続を閉じること。
- `Transfer-Encoding` と `Content-Length` が共存するリクエストで `Transfer-Encoding` が優先されること。
- 1 バッファに 2 つの完全なリクエストを含む keep-alive ケースで、2 つ目のリクエストが正しく処理されること。

テストはネットワーク層の分割送信を再現するため、`curl` ではなく raw ソケットで実装する。
`Content-Length` 不正値（負数、非数値、1 MiB 超）に対して正しいステータスを返すことも検証する。

---

### P0-2: DSL シグネチャとランタイムの arity 不整合修正

#### 問題

一部の API において、ランタイムのディスパッチテーブル、`dsl/sig.awk`、README ドキュメントの 3 者間で arity が一致していない。
既知の不整合は以下のとおりである。

- `hawk.app.on`: ランタイムは 3 引数（method, path, handler）だが、DSL シグネチャは 2 引数
- `ctx.res.redirect`: ランタイムは 2 引数（url, code）をサポートするが、DSL シグネチャは 1 引数のみ
- `safe.html.fragment`: `dsl/sig.awk:107-110` は既に variadic 宣言済みだが、ランタイムディスパッチは 3 引数固定（`_SAFE_ARITY["html.fragment"] = 3`）のため、4 引数以上を渡すとランタイム/デシュガーが対応していない

#### 要求仕様

**`hawk.app.on`** の論理的なシグネチャは以下とする。

```
(Str|Array, Str|Array, HandlerName) -> Void
```

`dsl/sig.awk` の arity を 3 に修正し、偽の型エラーが発生しないようにする。

**`ctx.res.redirect`** はオプション引数形式を採用する。

```awk
ctx.res.redirect(url)        # 302 を使用
ctx.res.redirect(url, code)  # 任意のリダイレクトコード
```

`dsl/sig.awk` における arity の扱いを、オプション引数に対応するよう修正する。
`ctx.res.redirect` のシグネチャエントリは min arity = 1、max arity = 2 として表現する。他の関数への汎用的な min/max arity 機構は本フェーズでは導入しない。`ctx.res.redirect` 専用の特殊ケースとして実装する。
`ctx.res.redirect(url)` は DSL デシュガー時に `ctx.res.redirect(url, 302)` に正規化する。
既存のディスパッチャーは arity 0〜3 の固定テーブルで動作するため、正規化後の 2 引数呼び出しとして扱う。

**`hawk.app.on`** は別の関数であり、`ctx.res.redirect` と arity の設計は独立している。
`hawk.app.on` はオプション引数を持たない固定 3 引数（method, path, handler）として実装する。

**`safe.html.fragment`** は可変長引数に対応する。
実装方法は `safe.html.fragment` 専用のスペシャルケースとし、汎用的な `hawk_dispatch::callv` は導入しない。

デシュガーの生成規則は以下のとおりである。

- 引数 0〜3 個：既存の `_SAFE_ARITY["html.fragment"] = 3` による固定 3 引数ディスパッチをそのまま使う（`hawk_dispatch::call3` を使用）。不足した引数は空文字列で埋める: 0 引数 → `html_fragment("", "", "")`、1 引数 → `html_fragment(arg1, "", "")`、2 引数 → `html_fragment(arg1, arg2, "")` に展開される。`call0`〜`call2` は **使わない**。
- 引数 4 個以上：展開ごとに一意な名前（`_ds_frag_args_N`、N はデシュガー内の単調カウンター）の AWK 配列に引数を格納し、`safe::fragment_v(_ds_frag_args_N, n)` を呼び出す特殊ディスパッチに展開する。配列は使用前にクリア（`delete _ds_frag_args_N`）する。

`safe::fragment_v(arr, n)` は `core/safe.awk` に追加するランタイム関数であり、`arr[1]`〜`arr[n]` を連結して返す。

0〜3 引数の空文字列パディング動作は現在の偶発的な動作であるため、明示的に仕様として定義し、テストで固定する。

#### 変更対象ファイル

- `dsl/sig.awk`
- `core/hawk.awk`
- `core/ctx.awk`
- `core/safe.awk`
- `core/dispatch.awk`
- `README.md`
- `tests/unit/dsl/` 内の関連 fixtures

#### 追加するテスト

- `hawk.app.on("GET", "/x", "h")` の DSL チェックが通ること。
- `ctx.res.redirect("/x")` の DSL チェックが通ること。
- `ctx.res.redirect("/x", 303)` の DSL チェックが通ること。
- `safe.html.fragment` に 4 引数以上を渡した場合のランタイムテスト。
- `safe.html.fragment` に 0 引数を渡すと `""` を返すこと（パディング動作の固定）。
- `safe.html.fragment` に 1 引数を渡すと `arg1` を返すこと。
- `safe.html.fragment` に 2 引数を渡すと `arg1 .. arg2` を返すこと。
- `safe.html.fragment` に 3 引数を渡すと `arg1 .. arg2 .. arg3` を返すこと。

---

### P0-3: TSV ストレージへの書き込みロック追加

#### 問題

TSV ヘルパー関数は複数ワーカーによる同時書き込みに対して安全でない。
具体的な危険性は以下のとおりである。

- `append_tsv` はロックなしで追記する。
- `delete_tsv` と `update_tsv` は固定のパス `path ".tmp"` を一時ファイルに使用しており、複数ワーカーが同一パスを競合して書き込む。
- `libs/net` が存在する場合はマルチワーカーモードが有効になるため、デモアプリの `data/todos.tsv` が破損するリスクがある。

#### 要求仕様

ロック機構は `mkdir` を使ったアトミックなロックディレクトリ方式で AWK 内に直接実装する。
シェルスクリプトへの委譲は行わない（AWK と外部プロセス間でロックのライフタイムを共有できないため）。

**オーナートークン:**

ロックディレクトリ取得後、取得したプロセスの PID をオーナートークンとしてロックディレクトリ内の `pid` ファイルに書き込む。
`tsv_unlock` はこのトークンを検証し、自プロセスが所有するロックのみを削除する。
これにより、タイムアウト後に別プロセスが取得したロックを誤って削除する競合状態を防ぐ。

**PID 再利用リスク（既知の制限）:**
オーナープロセスが死亡後に別のプロセスが同じ PID を再利用した場合、`kill -0` チェックが生存中と誤判定してスタールロックを検出できない。これは POSIX PID 再利用の根本的な制限であり、本フェーズでは許容する。将来的にはロック取得時刻（`systime()`）をトークンに含め、取得から一定時間経過後は強制リープを行うことで改善できる（本仕様には含まない）。

**ロック取得・解放の対象操作:**
`append_tsv`、`update_tsv`、`delete_tsv` の 3 関数がロックを使用する。各関数は `tsv_lock` 呼び出し後、処理完了（成功・失敗を問わず）の後に `tsv_unlock` を呼び出す。すべての early return パスで `tsv_unlock` が呼ばれることを保証するため、各関数の AWK コードは以下のパターンに従う。

```awk
function append_tsv(path, record,    ok) {
    if (!tsv_lock(path)) return 0
    # ... 本体処理 ...
    tsv_unlock(path)
    return 1
}
```

`tsv_lock` が失敗した場合（タイムアウト）は `tsv_unlock` を呼ばない（ロックを取得していないため）。`tsv_lock` が成功した後は、AWK に例外機構がないためすべての分岐で `tsv_unlock` を明示的に呼び出すこと。

**ロック取得:**

```awk
function tsv_lock(path,    lockdir, pidfile, pid, i, reapdir, no_pid_count) {
    lockdir = path ".lock"
    pidfile = lockdir "/pid"
    for (i = 0; i < 50; i++) {
        if (system("mkdir " _shellquote(lockdir) " 2>/dev/null") == 0) {
            # ロック取得: PID をオーナートークンとして書き込む
            print PROCINFO["pid"] > pidfile
            if (close(pidfile) != 0) {
                # PID 書き込み失敗: ロックを解放して失敗を返す
                system("rm -rf " _shellquote(lockdir))
                return 0
            }
            return 1
        }
        # スタールロック検出: PID ファイルを読んでオーナーが生存しているか確認する
        if ((getline pid < pidfile) > 0) {
            close(pidfile)
            # PID を数字のみに制限してシェルインジェクションを防ぐ
            if (pid !~ /^[0-9]+$/) {
                # 不正な PID ファイル: アトミックなリネームで横取りして削除する
                _tsv_seq++
                reapdir = lockdir ".reap." PROCINFO["pid"] "." _tsv_seq
                if (system("mv " _shellquote(lockdir) " " _shellquote(reapdir) " 2>/dev/null") == 0) {
                    system("rm -rf " _shellquote(reapdir))
                }
                continue
            }
            if (system("kill -0 " pid " 2>/dev/null") != 0) {
                # オーナープロセスが死亡 → アトミックなリネームで横取りしてから削除する
                # 2 つのリーパーが同時に kill-0 を通過しても、mv はアトミックなので
                # 一方だけが成功し、他方は mv 失敗後に continue して再試行する
                _tsv_seq++
                reapdir = lockdir ".reap." PROCINFO["pid"] "." _tsv_seq
                if (system("mv " _shellquote(lockdir) " " _shellquote(reapdir) " 2>/dev/null") == 0) {
                    system("rm -rf " _shellquote(reapdir))
                }
                # mv 失敗は他のリーパーまたはオーナーが処理済み → continue で再試行する
                continue
            }
        } else {
            close(pidfile)
            # PID ファイルが読めない or 存在しない
            # ケース: プロセスが mkdir 後・pid 書き込み前に死亡（スタールロック）
            # 対策: _tsv_no_pid_count で連続した読み取り失敗を追跡し、
            #       閾値（5 回）を超えたらアトミック mv でリープを試みる
            no_pid_count++
            if (no_pid_count >= 5) {
                no_pid_count = 0
                _tsv_seq++
                reapdir = lockdir ".reap." PROCINFO["pid"] "." _tsv_seq
                if (system("mv " _shellquote(lockdir) " " _shellquote(reapdir) " 2>/dev/null") == 0) {
                    system("rm -rf " _shellquote(reapdir))
                }
                continue
            }
            # まだ書き込み中の可能性があるため待機して再試行する
        }
        system("sleep 0.1 2>/dev/null || sleep 1")
    }
    return 0  # タイムアウト
}

function tsv_unlock(path,    lockdir, pidfile, pid) {
    lockdir = path ".lock"
    pidfile = lockdir "/pid"
    # オーナートークン検証: 自プロセスが所有するロックのみを削除する
    if ((getline pid < pidfile) > 0) {
        close(pidfile)
        if (pid == PROCINFO["pid"]) {
            system("rm -rf " _shellquote(lockdir))
        }
    } else {
        close(pidfile)
    }
}
```

`_shellquote(s)` は `core/tsv.awk` 内に既に実装済みの AWK ヘルパー関数である（`gsub(/'/, "'\\''", s)` を使い結果を `'` で囲む）。

**一時ファイルのパス:**
テンポラリファイルのパスはプロセス ID と単調増加カウンターを使って生成し、グローバルな乱数状態（`srand` / `rand`）に依存しない。

```awk
# BEGIN ルールで初期化する
_tsv_seq = 0

# テンポラリパス生成
function tsv_tmppath(path) {
    _tsv_seq++
    return path ".tmp." PROCINFO["pid"] "." _tsv_seq
}
```

`mv` は `system("mv " _shellquote(tmppath) " " _shellquote(path))` で実行し、戻り値を確認する。
失敗した場合は `system("rm -f " _shellquote(tmppath))` でクリーンアップしてエラーを返す。
すべてのコマンド引数に `_shellquote()` を適用する。

#### 変更対象ファイル

- `core/tsv.awk`
- `tests/unit/test_tsv.awk`

#### 追加するテスト

- `delete_tsv` と `update_tsv` が固定の共有 tmp パスを使用していないこと。
- ロック実装後、繰り返し書き込みを行うスモークテストが通ること。
- `mv` 失敗時にテンポラリファイルが残留しないこと。
- スペース・引用符・セミコロンを含むパスでロックが正常動作すること。
- 死亡プロセスの PID を持つスタールロックが自動解除されること。

---

### P0-4: DSL 波括弧カウントの文字列・コメント認識

#### 問題

`_ds_net_braces` は文字列リテラルおよびコメント内の `{` と `}` もカウントしている。
これにより、以下のような関数境界の追跡が誤った結果を生む。

```awk
function f() -> Str {
  let json: Str = "{\"ok\": true}"
  return json
}
```

上記のコードでは文字列内の `{}` がカウントされ、関数の終端検出が失敗する。

#### 要求仕様

`_ds_net_braces` のカウント対象をコードセグメントのみに限定する。
文字列リテラルおよびコメント内の波括弧はカウントしない。
既存のヘルパー `_ds_split_code_segs()` を使って実装し、生の文字スキャンを置き換える。

`_ds_split_code_segs()` が以下のケースを正しく処理することを実装前に確認し、対応していない場合は先に修正する。

- エスケープシーケンスを含む文字列（例: `"{\"ok\": true}"`）
- H-awk の文字列連結構文（隣接する文字列リテラルを 1 行内で連結する形式、例: `"hello" " " "world"`）。`_ds_split_code_segs()` は 1 行単位で動作するため、複数行にまたがる文字列連結は各行を独立して処理し、状態を行をまたいで引き継がない。
- コメント行（`#` 以降）

#### 変更対象ファイル

- `dsl/desugar.awk`
- `dsl/desugar_strings.awk`（`_ds_split_code_segs()` に不足がある場合）
- `tests/unit/dsl/` 内の新規 fixtures

#### 追加するテスト

以下の各パターンに対応する DSL fixtures を追加する。

- `{` を含む文字列リテラル
- `}` を含む文字列リテラル
- エスケープ済み引用符を含む JSON 文字列を内部に持つ関数
- `{` を含むコメント
- `}` を含むコメント

---

## Phase 2: P1 Correctness Fixes

### P1-1: `ctx.req.*` の欠損と空値の区別

#### 問題

現在のヘルパーは空文字列と欠損キーを同一視している。
たとえば `title=` のようにフォームフィールドが存在しても値が空の場合、以下のパターンは欠損として誤判定する。

```awk
v = ctx::req["form:" key]
return v != "" ? result_ok_make(v) : result_ng("ParseError", "missing " key)
```

#### 要求仕様

値チェック（`v != ""`）をキー存在チェック（`("form:" key) in ctx::req`）に置き換える。
適用対象は以下のとおりである（`ctx::req_json` はここでの変更対象ではない。詳細は下記）。

- `ctx::query`
- `ctx::param`
- `ctx::get_header`
- `ctx::req_form`

`ctx::body` については以下のセマンティクスを明示する。
`ctx::body` は値チェックではなくキー存在チェックに変更する（`("body") in ctx::req`）。
ハンドラーが呼び出される時点でリクエストは必ず完全に受信済みである（P0-1 で保証）。
`Content-Length: 0` の場合、またはボディ区切り後のバイト列が 0 バイトの場合は `ok("")` を返す（空ボディはキー「body」が存在し値が空文字列として格納される）。

`ctx::req_json` は独立した仕様を持ち、キー存在チェックへの置き換えは適用しない。

**`ctx::req_json` の仕様**:

- **戻り値型**: `Result<Str, ParseError>`。`ok` 値は元のリクエストボディ文字列（そのまま保持）。`ParseError` 値はエラー理由文字列。
- `request.awk` の `_request_parse_json_body` は既に `req["json:" key]` にフラット展開済みであるため、DSL から `ctx.req.json_field("key")` でアクセスできる。`ctx.req.json()` は JSON ボディ全体を raw string として返す（デコード済みマップを返さない）。
- **`dsl/sig.awk` 変更**: `ctx.req.json` のシグネチャを現在の `Result<Untrusted<Map>, ParseError>` から `Result<Str, ParseError>` に変更する。`dsl/sig.awk` を変更対象ファイルに追加する。
- **`ctx.req.json_field` のシグネチャ**: `(Str) -> Result<Str, ParseError>` として `dsl/sig.awk` に登録する。このヘルパーは `req["json:" key]` へのアクセスをラップし、キー存在チェックを行う（`ctx.req.json()` が `ok` を返した後に使用する）。
- `ctx::req_json` の `ParseError` 条件: ボディが JSON として無効な場合。具体的には: (a) ボディが空（`Content-Length: 0` または `Content-Type: application/json` 付きのゼロバイトボディ）、(b) ボディが JSON 構文として解析不能、(c) `Content-Type: application/json` が付いていない場合（`Content-Type` なしは `ParseError`）。
- `ctx::body` と `ctx::req_json` の動作は独立している。`ctx::body` が `ok("")` を返す（空ボディ）ケースでも、`ctx::req_json` は `ParseError` を返す。この 2 者の動作は矛盾しない: 空ボディは「ボディとしては存在するが JSON ではない」という扱いである。

#### 変更対象ファイル

- `core/ctx.awk`
- `dsl/sig.awk`（`ctx.req.json` のシグネチャ変更 + `ctx.req.json_field` 追加）
- `tests/unit/test_ctx.awk`
- `tests/unit/test_request.awk`

#### 追加するテスト

- 空値を持つクエリパラメータが `ok("")` を返すこと（`?key=` の形式）。
- 空値を持つフォームフィールドが `ok("")` を返すこと（`key=` の形式）。
- 欠損キーが `ParseError` を返すこと。
- 空ボディ（`Content-Length: 0`）が `ok("")` を返すこと。
- `ctx.req.json_field("key")` が JSON ボディから指定キーの値を返すこと。
- `ctx.req.json_field("missing")` が `ParseError` を返すこと。

---

### P1-2: `ctx.res.json` セマンティクスの修正

#### 問題

低レベルの `response.awk` における `json(res, data)` は `json_encode(data)` でデータをエンコードする。
一方、コンテキストヘルパー `ctx::json(data)` はデータをエンコードせずそのままレスポンスボディに入れる。
この非対称性により、`ctx.res.json` は事実上 `ctx.res.json_raw` として動作している。

#### 要求仕様

`ctx.res.json(data)` は AWK 配列または値を `json_encode` でエンコードしてからレスポンスボディにセットする。
エンコードは新たに実装する `json_encode_any(val)` 関数を使う。
既存の `json_encode` は `for (key in data)` による配列専用であり、スカラーを渡すと不定動作になる。
`json_encode_any` のエンコード規則は以下のとおりである。

AWK の JSON データモデルを以下のように定義する。

- **JSON オブジェクト**：AWK 配列で `arr["key"] = value` の形式。`arr["__json_type"]` が `"array"` でない場合はオブジェクトとして扱う。`__json_type` キー自体は JSON 出力に含めない。
- **JSON 配列**：AWK 配列で `arr["__json_type"] = "array"` かつ `arr[1]`, `arr[2]`, ... の整数インデックスを使う。配列長の決定ルールは以下の優先順位で適用する: `arr["n"]` が存在する場合はその値を要素数として使う; `arr["n"]` が存在しない場合はすべての正の整数キーを列挙して最大インデックスを要素数とする。`length(arr) - 1` は使わない（メタキー `__json_type` のほか `n` 等が含まれると誤った値になるため）。スパース配列（`arr[1]`, `arr[3]` のみで `arr[2]` が欠落）は `null` で埋める。

エンコード規則は以下のとおりである。

- `isarray(val)` が真かつ `val["__json_type"] == "array"`：JSON 配列として `[val[1], val[2], ..., val[n]]` を生成する。各要素は `json_encode_any` を再帰的に呼び出してエンコードする。
- `isarray(val)` が真かつ `val["__json_type"] != "array"`：JSON オブジェクトとして生成する。`__json_type` キーおよびキー `"n"` を除いた各キーと値を `json_encode_any` で再帰的にエンコードする（`"n"` は JSON 配列の長さメタキーとして予約されており、オブジェクト出力からも除外する）。既存の `json_encode` はスカラー値を扱えないため、`json_encode_any` 自身で再帰処理を実装する。AWK の配列イテレーション順は未定義のため、テストでは厳密な文字列比較ではなく、期待するキーと値のペアがすべて含まれることを検証する（JSON パーサーで parse して比較するか、`sort` 済み出力で比較する）。注: `"n"` キーの予約によって純粋な JSON オブジェクトに `"n"` を格納できなくなる。これは既知のトレードオフであり、本 ADT の配列表現の制約として README に記載する。
- `typeof(val) == "number"`：JSON 数値（クォートなし）に変換する。
- `typeof(val) == "strnum"`（数値として解釈可能な文字列、例: `"42"`, `"001"`, `"1e2"`）：JSON 文字列として扱う（クォートあり）。AWK の `strnum` は文字列として渡されたものであり、呼び出し元が数値として意図した場合は `typeof` で区別できないためである。注: 式の評価（連結、算術演算、配列格納）によって値の型カテゴリが変化するため、`json_encode_any` に渡す前に `typeof` で安定した出力を得るには、呼び出し元が数値リテラル（`+0` 算術変換など）または文字列リテラルとして明示的に構築する必要がある。この不安定性は AWK の型システムの制約であり、仕様の範囲内として受け入れる。
- それ以外（通常の文字列）：JSON 文字列（`"..."` 形式、`\"`・`\\`・`\n`・`\r`・`\t`・制御文字をエスケープ）に変換する。
- `null`・真偽値は AWK の型システムに存在しない。`"null"`・`"true"`・`"false"` は文字列として JSON 文字列に変換する。

追加するテストは以下のとおりである。
- AWK 配列（オブジェクト形式）が JSON オブジェクトに変換されること。
- `arr["__json_type"] = "array"` の配列が JSON 配列 `[...]` に変換されること（`__json_type` が出力に含まれないこと）。
- 整数リテラル `42` が `42` に変換されること（クォートなし）。
- 文字列 `"42"` が `"42"` に変換されること（クォートあり）。
- 浮動小数点 `3.14` が `3.14` に変換されること。
- 空文字列 `""` が `""` に変換されること。
- エスケープが必要な文字列（ダブルクォート、バックスラッシュ、改行）が正しく変換されること。
- 空配列（要素なし、`__json_type = "array"` のみ）が `[]` に変換されること。
- オブジェクト内にネストされた配列が正しく変換されること。

事前エンコード済みの JSON 文字列を直接セットするためのヘルパーとして `ctx.res.json_raw(str)` を追加する。

`dsl/sig.awk` における `ctx.res.json` のシグネチャは、引数型を `Any`（AWK 配列・スカラーを問わず受け付けることを示す）に変更する。型チェックレイヤーは `ctx.res.json(v)` の引数 `v` に対して型エラーを出さない（引数型を `Any` として扱う）。`ctx.res.json_raw` は `Str` を引数に取る。

この変更は破壊的変更である。`ctx.res.json` に pre-encoded JSON 文字列を渡している既存コードはすべて二重エンコードになる。
修正対象のファイルは以下のとおりである（すべて確認・修正すること）。

- `app.awk`
- `tests/e2e/fixtures/app.awk`
- `tests/unit/test_ctx.awk` 内の既存テスト

#### 変更対象ファイル

- `core/json.awk`（`json_encode_any` をここに追加する。`json_encode` と同じファイルに置くことで JSON エンコードポリシーを一箇所に集約する）
- `core/response.awk`
- `core/ctx.awk`
- `dsl/sig.awk`
- `app.awk`
- `README.md`
- `tests/unit/test_ctx.awk`
- `tests/e2e/fixtures/app.awk`

#### 追加するテスト

- `ctx.res.json(data)` が AWK 配列を JSON オブジェクトにエンコードして返すこと。
- `ctx.res.json("hello")` が JSON 文字列 `"hello"`（ダブルクォートを含む）を返すこと（二重エンコードでないこと）。
- `ctx.res.json(42)` が JSON 数値 `42` を返すこと。
- `ctx.res.json_raw(str)` が文字列をそのままボディにセットすること。
- e2e の `/echo` エンドポイントが引き続き有効な JSON を返すこと。

---

### P1-3: `when...of` パイププリルードへの dot 変換適用

#### 問題

通常の関数本体内では、パイプが生成するプリルード行に `_ds_dot_transform` が適用される。
`when...of` 本体内では、`_ds_match_process_body` がパイププリルード行を `_DS_body_buf` に挿入する際、`_ds_dot_transform` を適用していない場合がある。
この結果、以下のような変換されていないコードが出力される。

```awk
_ds_p_1 = safe.html.escape(raw)
```

正しい出力は以下となるべきである。

```awk
_ds_p_1 = safe::dispatch("html.escape", raw)
```

#### 要求仕様

`_ds_match_process_body` において、`pipe_pre[p]` を `_DS_body_buf` に追加する前に `_ds_dot_transform` を適用する。

#### 変更対象ファイル

- `dsl/desugar_match.awk`
- `tests/unit/dsl/` 内の新規 fixture

#### 追加するテスト

以下の入力に対して、出力に `safe::dispatch("html.escape", raw)` が含まれ、`safe.html.escape(raw)` が含まれないことを検証する。

```awk
function h() -> Response {
  when ctx.req.form("title") of
    ok raw:
      let escaped = raw |> safe.html.escape()
      return ctx.res.html(escaped)
    ng:
      return ctx.res.status(400)
  end
}
```

---

### P1-4: `when...of` catch-all アームの順序バリデーション

#### 問題

`default:` または非型付き `ng:` は `else { ... }` を生成する。
catch-all アームの後に型付き `ng e<Foo>:` が続く場合、生成される AWK コードが構文的に無効になる。

```awk
else {
  ...
} else if (...) {
  ...
}
```

#### 要求仕様

catch-all アームは `when...of` 式の最後のエラーアームとしてのみ許可し、それ以外の位置ではデシュガー時にエラーを出力する。

**catch-all アーム**の種類は以下のとおりである。

- `ng:`（Result の非型付きエラーキャッチ）
- `ng err:`（Result の非型付きエラーキャッチ、変数束縛あり）
- `default:`（Result の非型付きキャッチオール）
- `default err:`（同上、変数束縛あり）
- `none:`（Option の非型付きキャッチ。`ok` アームが存在する場合の最終アーム）

`none:` は Option 式の最終アームとして許可する。
Result 式と Option 式が混在する `when...of` はサポート対象外であり、混在が検出された場合は別途エラーを出力する。
アーム種別（Result か Option か）の判定は以下のヒューリスティックで行う: アームに `none:` が含まれれば Option、`ok` or `some` のみがあり `ng` がなければ Option、`ng` アームが 1 つでもあれば Result として扱う。デシュガーフェーズではスクルーティニーの型情報は利用できないため、アーム名のパターンで判定する。両種のアームが混在する場合は「混在 Result/Option arms」エラーを出力する。

バリデーションは `_DS_match_ng_is_default` フラグを利用せず、アームの型付き / 非型付きを直接判定する方式で実装する。

アームの有効な順序は以下の規則に従う（Result 式と Option 式は別々の規則を持つ）。

**Result 式の有効なアーム順序:**
- `ok [bind]` アームは最初に置く（複数不可。2 つ以上あるとエラー）
- 型付き `ng e<Type>:` アームは `ok` の後、catch-all の前に置く（順序任意。同一型の重複はエラー）
- catch-all（`ng:`, `ng err:`, `default:`, `default err:`）は必ず最後の 1 つだけ

無効なパターン：
- catch-all の後に型付き `ng e<Type>:` が続く → エラー
- 重複した catch-all → エラー
- `ok` アームが 2 つ以上ある → エラー
- Result 式に `none:` が含まれる → エラー

**Option 式の有効なアーム順序:**
- `ok [bind]:` アーム（または `some [bind]:` と記述する場合）を最初に置く（1 つのみ）
- `none:` は最後の catch-all として 1 つだけ許可

無効なパターン：
- `none:` の後にアームが続く → エラー
- Option 式に `ng e<Type>:` が含まれる → エラー
- `ok` アームが存在しない（`none:` のみ）→ エラー

注: 既存コード（`desugar_match.awk`）は `some:` アームを `ok` の別名として処理する。本フェーズでは `some:` と `ok:` を同等として扱い、どちらの記法も許可する。

catch-all アームの後に型付きアームが続く場合は、以下のエラーメッセージを出力する。

```
catch-all arm must be last
```

#### 変更対象ファイル

- `dsl/desugar_match.awk`
- `tests/unit/dsl/` 内の新規 fixture
- `README.md`

#### 追加するテスト

以下の無効な入力に対して `catch-all arm must be last` エラーが出力されることを検証する。

```awk
when fetch_user(id) of
  ok user:
    return ctx.res.text(user)
  default:
    return ctx.res.status(500)
  ng e<AuthError>:
    return ctx.res.status(401)
end
```

---

### P1-5: `render()` パスの制限

#### 問題

`template_read(path)` は任意のパスを読み取れる。
アプリコードが信頼できない入力を `ctx.res.render` に渡すと、任意ファイル読み取りになる。

#### 要求仕様

テンプレートパスのAPIを以下のとおり定義する。

**呼び出し側 API**:
- 呼び出し元は `views/` プレフィックス付きの相対パスを渡す（例: `ctx.res.render("views/index.html")`）。
- 以下は事前チェックで即時拒否する（`realpath` 実行前）: 絶対パス（`/` 始まり）、`..` を含むパス、空文字列、`views/` プレフィックスなしのパス。

**`HAWK_TEMPLATE_ROOT`**:
- アプリルートディレクトリの絶対パス（`views/` の親ディレクトリ）を指す。
- `libexec/hawk-serve` がプロセス起動時に環境変数として設定する。`bin/hawk` は設定しない。
- 例: アプリが `/app` にある場合、`HAWK_TEMPLATE_ROOT=/app`。
- **HAWK_TEMPLATE_ROOT が未設定の場合**: `render()` は即座に `500 Internal Server Error` を返す（fail-closed）。これにより、直接 `gawk` 呼び出しやユニットテストなど `hawk-serve` を経由しない実行パスで `render()` が意図せず成功することを防ぐ。ユニットテストで `render()` の成功パスをテストする場合は、テスト側で `HAWK_TEMPLATE_ROOT` を設定する（`tests/e2e/fixtures/app.awk` のテストでは `HAWK_TEMPLATE_ROOT=tests/e2e/fixtures` を設定する）。

**パス正規化**:

1. `HAWK_TEMPLATE_ROOT` 自体を `realpath` で正規化する（サーブ起動時に 1 回のみ実行し、`_hawk_template_root` 変数にキャッシュする）。また `_hawk_template_views = _hawk_template_root "/views"` もキャッシュする。
2. 候補パスを `_hawk_template_root "/" path` として構築する。`path = "views/index.html"` なら `candidate = "/app/views/index.html"`。二重 `views/` にはならない（呼び出し元が `views/` プレフィックス付きで渡し、それをそのまま結合するため）。

```awk
candidate = _hawk_template_root "/" path
cmd = "realpath -- " _shellquote(candidate) " 2>/dev/null"
ret = (cmd | getline normalized)
close(cmd)
if (ret != 1) {
    return render_error(500, "template path could not be verified")
}
```

3. `normalized` が `_hawk_template_views` と等しいか、または `_hawk_template_views "/"` で始まるかを確認する。

```awk
if (normalized != _hawk_template_views && index(normalized, _hawk_template_views "/") != 1) {
    return render_error(500, "template path outside root")
}
```

シンボリックリンクは `realpath` が解決済みの実パスに展開するため、`HAWK_TEMPLATE_ROOT/views/` 配下に収まることで保証する。
テンプレートファイルは `normalized` を使って読み込む（元の `path` や `candidate` は使わない）。

`realpath` が利用できない環境（戻り値 `!= 1`）では fail-closed とし、`500 Internal Server Error` を返す。
`realpath` の利用可否は `hawk serve` 起動時に `realpath -- /dev/null 2>/dev/null` の終了コードで確認する。利用不可の場合は stderr に警告を出力して起動を継続する（起動を中止しない）。その後 `render()` の呼び出しは毎回 fail-closed で 500 を返す。

`dsl/sig.awk` における `ctx.res.render` のシグネチャは引数 1 個（`Str`）として登録する。他の引数は受け付けない（arity = 1 固定）。

長期的な設計として `TemplatePath` ブランド型の導入を検討するが、本フェーズでは短期的なランタイムチェックのみを実装する。

#### 変更対象ファイル

- `core/template.awk`
- `core/response.awk`
- `core/ctx.awk`
- `dsl/sig.awk`
- `README.md`
- `tests/unit/test_template.awk`
- `tests/e2e/fixtures/app.awk`（既存の `ctx.res.render("tests/e2e/fixtures/views/test.html")` を `ctx.res.render("views/test.html")` に更新し、テスト実行時に `HAWK_TEMPLATE_ROOT=tests/e2e/fixtures` が設定されることを確認する）
- `libexec/hawk-serve`（`realpath` の利用可否を起動時に確認する処理を追加）

#### 追加するテスト

- `ctx.res.render("views/index.html")` が成功すること。
- `ctx.res.render("../secret")` が失敗すること。
- 絶対パスが失敗すること。
- 空文字列が失敗すること。
- `views/` 配下からルート外へのシンボリックリンク（例: `views/link -> /etc/passwd`）が `HAWK_TEMPLATE_ROOT` 外として拒否されること。
- `views2/foo` のようなルートと共通プレフィックスを持つが配下でないパスが拒否されること。

---

## Phase 3: P2 Design Cleanup

### P2-1: `?=` エラーマッピングの改善

#### 問題

`?=` は現在、型に関わらず `Option none` を `404`、`Result ng` を `500` にマッピングする。
リクエスト解析エラーや認証エラー、バリデーションエラーを正しく表現できない。

#### 要求仕様

エラー型に基づくデフォルトマッピングを導入する。

- `ParseError` → 400
- `AuthError` → 401
- `NotFoundError` → 404
- 未知のエラー → 500
- `Option none` → 404（従来どおり）

`Result ng` の型判定は `result_ng` の第 1 引数（エラー種別文字列）を取得するアクセサー `result_err_type(r)` で実装する。
この関数が存在しない場合は `dsl/adt.awk` に追加する（デシュガーレイヤーが参照するため、`core/adt.awk` ではなくデシュガー層のファイルに置く）。
デシュガーが生成するコードは `result_err_type` を呼び出してマッピングテーブルを参照するパターンを使う。

追加するテストは以下のとおりである。
- `ParseError` を含む `Result ng` が `?=` で 400 に変換されること。
- `AuthError` を含む `Result ng` が `?=` で 401 に変換されること。
- `NotFoundError` を含む `Result ng` が `?=` で 404 に変換されること。
- 未知のエラー型が `?=` で 500 に変換されること。
- `Option none` が `?=` で 404 に変換されること（従来動作の確認）。

エラー型の文字列マッチングルールは以下のとおりである。
- `result_err_type(r)` が返す文字列と上記マッピングキーを完全一致で比較する。
- エイリアス型（`type MyError = ParseError`）は型名として `"MyError"` を使うため、`"ParseError"` とはマッチしない。エイリアスが 400 にマッピングされるべき場合は `type MyError = ParseError` ではなく `result_ng("ParseError", msg)` を使うよう README に記載する。
- union エラー型（`AuthError|ParseError`）を `result_ng` に渡すケースは AWK の ADT ランタイムでは発生しない（`result_ng` は 1 つのエラー種別文字列をとるため）。
- 名前空間付きエラー文字列（例: `"Pkg::ParseError"`）はマッピングテーブルに存在しないとみなし `500` を返す。

将来的には `let body ?= ctx.req.json() else 400` のような構文拡張を検討する。

#### 変更対象ファイル

- `dsl/desugar_nullcoalesce.awk`
- `dsl/adt.awk`（`result_err_type` は `dsl/adt.awk:60` に既に実装済みのため変更不要）
- `README.md`

---

### P2-2: `classify: validator` セマンティクスの修正

#### 問題

README は `validator` が `Untrusted<T>` を受け取り plain `T` を返すと説明しているが、現在の実装は `transform` と同じ動作をしており `Untrusted` ラッパーを保持している。

#### 要求仕様

各 classify 種別のデータフローセマンティクスを以下のとおり定義する。

- **`transform`**: `Untrusted<T>` → `Untrusted<T>`（ラッパーを保持）
- **`validator`**: `Untrusted<T>` → `T`（ラッパーを除去）
- **`sanitizer`**: ブランドセーフな型を返す
- **`sink`**: 終端コンシューマー

`classify: validator` は純粋な静的な信頼境界アノテーションである。「この関数はデータが有効であることを確認してから返す」という意図を型システムに伝えるものであり、ランタイムの成功/失敗とは独立している。
`Untrusted<T>` を `validator` 関数に渡した場合、戻り値の型は `T`（`Untrusted` なし）として扱われる。これは「この関数を通過したデータは検証済みである」という静的な信頼付与である。
ランタイムでバリデーションが失敗しうる（例: 長さチェック、形式チェック）場合は `Result<T, E>` を返す通常の関数として実装する。`classify: validator` は「成功すれば信頼済み」という前提を静的に注入するためのものであり、失敗パスを扱わない。

**セキュリティ上の注意点（既知のガードレール不足）:**
`classify: validator` は関数名や実装内容に関わらず信頼付与を行うため、実際に検証を行わない関数に付与すると未検証データが `Untrusted` なしで伝播する。これは意図的な設計（プログラマーの宣言的責任）であるが、誤用リスクがある。本フェーズでは型チェッカーによる自動検証（本文中に検証ロジックがあるかチェックするなど）は行わない。README に「`classify: validator` を付与できるのは、実際に入力を検証してから返す関数に限る」と明記し、コードレビューで確認することとする。

#### 変更対象ファイル

- `dsl/type_dataflow.awk`
- `README.md`
- `tests/unit/dsl/untrusted_validator_propagates/`（既存 fixture の期待値修正）

#### 追加するテスト

- `classify: validator` 関数に `Untrusted<Str>` を渡した場合、戻り値の型が `Str`（`Untrusted` なし）として扱われること。
- `classify: transform` 関数に `Untrusted<Str>` を渡した場合、戻り値の型が `Untrusted<Str>` のままであること。

---

### P2-3: 複合型再代入での `type::coerce` 回避

#### 問題

型付き再代入は現在 `type::coerce(rhs, "Type")` でラップする。
`type::coerce` がサポートするのは `Int`、`Float`、`Str`、`Bool` のみであるため、以下の複合型への再代入がランタイムエラーになる。

- union 型
- alias 型
- ブランド型
- `Option<T>`
- `Result<T, E>`
- `Effect<T>`

#### 要求仕様

複合型への再代入では `type::coerce` を使用しない。
複合型への再代入では `type::coerce` を生成せず、型アノテーションなしのシンプルな代入にデシュガーする。
`type::accepts(expected, actual)` は型文字列同士の互換性チェック（静的）であり、ランタイム値の検査には使用できない（引数の意味が違うため）。
したがってランタイムアサーション（`type::assert_accepts`）は本フェーズでは導入しない。

複合型への再代入の生成規則は以下のとおりである。

- プリミティブ型（`Int`, `Float`, `Str`, `Bool`）：従来どおり `type::coerce(rhs, "Type")` を生成する
- union 型、alias 型、ブランド型、`Option<T>`、`Result<T,E>`、`Effect<T>`：`var = rhs` のみを生成する（`type::coerce` を生成しない）

DSL の型チェックフェーズがエラーなく通過していれば、型の整合性は静的に保証されている。
ブランド型への強制変換はデシュガー層でも行わない。

#### 変更対象ファイル

- `dsl/desugar_let.awk`
- `core/adt.awk` は変更なし（型ランタイムの変更は最小限にとどめる）

#### 追加するテスト

- union 型への再代入が `type::coerce` を生成しないこと（デシュガー出力の確認）。
- `Option<Str>` への再代入が `type::coerce` を生成しないこと。
- ブランド型への再代入が `type::coerce` を生成しないこと。
- プリミティブ型（`Int`, `Str`）への再代入は従来どおり `type::coerce` を使うこと（回帰テスト）。

---

### P2-4: レスポンスヘッダー名のバリデーション

#### 問題

ヘッダーの値から CRLF を除去しているが、ヘッダー名はバリデーションしていない。
無効なヘッダー名が `response_wire` から出力される可能性がある。

#### 要求仕様

ヘッダー名の検証は `header()` / `ctx.res.set_header()` の呼び出し時点で行う。

**`header()` / `ctx.res.set_header()` での動作（早期拒否）:**

無効なヘッダー名が渡された場合、そのヘッダーを `res[]` 配列に格納せず、stderr に警告を出力する。レスポンスの処理は続行する（当該ヘッダーが欠落した状態で継続）。これにより汚染されたヘッダーが `res[]` に入ることを防ぐ。

**`response_wire` での動作（最終プリフライト）:**

`res[]` 配列内のヘッダー名を再検証する防衛的チェックとして、`response_wire` でも全ヘッダー名を検証する。無効なヘッダー名が 1 件でも残存していた場合は、元の `res` 配列とは独立したフレッシュなオブジェクトから `500 Internal Server Error` レスポンスを構築して出力する。これにより汚染された `res` 配列の内容が部分的に出力されることを防ぐ。警告を stderr に出力する。

**有効なヘッダー名:**

すべてのヘッダー名を以下の正規表現で検証する。

```
^[!#$%&'*+.^_`|~0-9A-Za-z-]+$
```

「無視」ではなく「警告＋欠落」とする理由は、無効なヘッダー名がサイレントに欠落すると API 呼び出し元がデバッグできないためである。`response_wire` 500 は二重の防衛として機能し、通常は `header()` の早期拒否で到達しない。

#### 変更対象ファイル

- `core/response.awk`
- `tests/unit/test_response.awk`

#### 追加するテスト

- 有効なカスタムヘッダーが出力されること。
- 改行文字を含むヘッダー名が拒否されること。
- コロンを含むヘッダー名が拒否されること。
- スペースを含むヘッダー名が拒否されること。

---

### P2-5: プラグイン探索の堅牢化

#### 問題

`plugin_discover()` はプラグインディレクトリごとに `plugin_<name>_manifest` 関数を無条件で呼び出す。
有効な manifest 関数を持たないディレクトリが存在する場合、gawk が失敗する。

#### 要求仕様

`manifest.awk` を持たないプラグインディレクトリはスキップして警告を出力し、存在しない関数を indirect-call しない。
`manifest.awk` は存在するが `plugin_<name>_manifest` 関数が定義されていない場合も同様にスキップして警告を出力する。
現在の `hawk-libs plugins` はプラグインディレクトリを走査し、`manifest.awk` と実装ファイルのパスを `-f flag` として出力する。
この仕組みを維持したまま、無効なマニフェストを事前にフィルタリングする方式に変更する。

**検証方式（プリフライトサブプロセス）:**

プラグインディレクトリ名は `^[a-zA-Z][a-zA-Z0-9_]*$` に一致する必要がある。
この検証を最初に行い、一致しない場合はスキップして警告を出力し、以降の処理を行わない。
これにより、`funcname` 変数やシェルコマンド文字列へのディレクトリ名の埋め込みが安全に行える。

名前が有効な場合、`hawk-libs plugins` が各プラグインの `-f manifest.awk` を出力する前に、以下のコマンドをサブプロセスで実行して事前検証する。

```bash
name="<plugin-name>"   # ^[a-zA-Z][a-zA-Z0-9_]*$ を満たす（検証済み）
funcname="plugin_${name}_manifest"
gawk -f "${manifest}" -e "BEGIN { if (!(\"${funcname}\" in FUNCTAB)) exit 1 }" 2>/dev/null
```

- 終了コード 0: `manifest.awk` の構文が正常かつ `plugin_<name>_manifest` 関数が定義済み → `-f "${manifest}" -f "${impl}"` を出力する。`${manifest}` と `${impl}` は `printf '%s'` でクォートする（パス中のスペースや特殊文字に対応するため）。呼び出し元が `eval` または `$()` でフラグを展開する場合は、この出力をシングルクォートで適切にエスケープすること（`printf '%q'` を使用する）。
- 終了コード 非ゼロ（構文エラーまたは関数未定義）: スキップして警告を stderr に出力する。`-f manifest.awk` を出力しない。

これにより、不正な構文や未定義関数を持つマニフェストが本体 gawk プロセスに `-f` で読み込まれることを防ぐ。
本体プロセスでのランタイム FUNCTAB チェックは行わない（既に安全なプラグインのみが読み込まれているため）。
注: プリフライト実行と本体プロセス起動の間にマニフェストが書き換えられる TOCTOU は残存する。本フェーズの目的はクラッシュ防止であり、完全なファイル整合性保証は対象外とする。

#### 変更対象ファイル

- `core/plugin.awk`
- `libexec/hawk-libs`

#### 追加するテスト

- `manifest.awk` が存在しないプラグインディレクトリがスキップされ、警告が出力されること。
- `manifest.awk` は存在するが `plugin_<name>_manifest` 関数が未定義のプラグインがスキップされ、警告が出力されること。
- `manifest.awk` が不正な AWK 構文（パースエラー）を含む場合にスキップされ、警告が出力されること。
- 有効な `manifest.awk` を持つプラグインが正常にロードされること（回帰テスト）。

---

## Phase 4: README 更新

Phase 1〜3 の実装完了後、`README.md` を以下の観点で更新する。

1. H-awk のアーキテクチャを明示する（CLI ラッパー、libexec サブコマンド、DSL プリプロセッシング、gawk ランタイム、オプションの Zig ライブラリの関係）。
2. TSV ストレージの `mkdir` ベースのロック実装を説明し、マルチワーカーでの利用条件を明示する。
3. `ctx.res.json` が AWK 配列と値を JSON エンコードすること、および `ctx.res.json_raw` が事前エンコード済み文字列用であることを説明する。
4. `safe.html.fragment` が可変長引数を受け付けることを明示する。
5. `render()` が `HAWK_TEMPLATE_ROOT` 配下のパスのみを許可すること。`realpath` が利用できない環境では fail-closed として 500 を返すこと。
6. `?=` のデフォルトエラーマッピング（型別対応表）を記載する。
7. 以下の使用例を追加する。
   - `hawk.app.on`（3 引数形式）
   - `ctx.res.redirect`（オプション引数形式）
   - `when...of` 基本構造
   - `when` アーム内のパイプ
   - 空フォーム値の処理

---

## Phase 5: 最終検証

全 Phase 完了後に以下を実行し、すべてのテストが通ることを確認する。

```sh
make lint
make test-dsl
make test-unit
make test-e2e
make ci
```

Zig 0.16.0 が利用可能な場合は追加で以下を実行する。

```sh
make test-libs
make ci-full
```

---

## 受け入れ条件

本作業の完了条件は以下のとおりである。

- 既存のテストがすべて通ること。
- 新しい回帰テストがすべて通ること。
- `hawk.app.on` の arity がランタイムと DSL チェッカーで一致していること。
- `ctx.res.redirect` の動作がランタイムと DSL チェッカーで一致していること。
- `safe.html.fragment` の動作がランタイム、DSL チェッカー、README で一致していること。
- `libs/net` が不完全な POST ボディをエンキューしないこと。
- `libs/net` がヘッダーサイズ超過（`MAX_HEADER_SIZE` = 8 KiB 超）で `431` を返すこと。
- `libs/net` が `Transfer-Encoding: chunked` に対して `501` を返し接続を閉じること。
- `libs/net` が任意の `Transfer-Encoding` 値（複数値・カンマ区切りを含む）に対して `501` を返し接続を閉じること。
- `libs/net` が無効・重複・負数の `Content-Length` に対して `400` を返すこと。
- `libs/net` が `MAX_BODY_SIZE` 超の `Content-Length` に対して `413` を返すこと。
- `ctx.req.form("x")` が `x=` に対して `ok("")` を返すこと。
- `ctx.res.json(data)` が AWK 配列を JSON エンコードすること。
- `when` アーム内のパイプ右辺の dot 記法が正しくデシュガーされること。
- 文字列内の波括弧が関数境界の解析を壊さないこと。
- TSV ストレージがロックによって安全に使用できること。
- 無効なレスポンスヘッダー名が拒否されること。
- `ctx.res.render("../secret")` が失敗すること（path traversal 保護）。
- `views/` 外へのシンボリックリンクが拒否されること。
- `views2/foo` のような共通プレフィックスを持つパスが拒否されること。
- `?=` が `ParseError` を 400 に、`AuthError` を 401 に、`NotFoundError` を 404 に、未知エラーを 500 にマッピングすること。
- `classify: validator` 関数が `Untrusted<T>` から `T` にアンラップすること。
- 複合型再代入が `type::coerce` を使わないこと。
- `ctx.res.json_raw(str)` が文字列をそのままボディにセットすること。
- TSV ロックが死亡 PID のスタールロックを自動解除すること。
- `render()` が `realpath` 利用不可の環境で fail-closed（500）を返すこと。
- プラグイン探索が `manifest.awk` 欠落または関数未定義のディレクトリをスキップすること。
- README が実際の動作と一致していること。

---

## コミット分割方針

以下の順序でコミットを分割する（フェーズ順に対応）。

Phase 1（P0）、Phase 2（P1）、Phase 3（P2）の順に対応する。

```
# Phase 1: P0 Critical Fixes
fix(net): add header size limit, reject oversized headers with 431
fix(net): wait for complete content-length body before enqueue
fix(net): return 501 and close for any transfer-encoding value
fix(dsl): align signature arities with runtime dispatch
fix(tsv): add mkdir-based write locking with PID owner token
fix(dsl): ignore braces inside strings and comments

# Phase 2: P1 Correctness Fixes
fix(ctx): distinguish missing request keys from empty values
fix(ctx): encode data in ctx.res.json, add json_raw helper
fix(dsl): transform pipe preludes inside when arms
fix(dsl): reject catch-all when arms before typed arms
fix(template): restrict render path to hawk_template_root
fix(response): reject invalid header names

# Phase 3: P2 Design Cleanup
fix(dsl): improve ?= error type mapping with type-based defaults
fix(dsl): fix validator classify to unwrap Untrusted
fix(dsl): avoid type::coerce for complex type reassignment
fix(response): add preflight header name validation
fix(plugin): tolerate missing or malformed manifest in plugin discovery

# Phase 4
docs: clarify storage, json, render, and DSL semantics
test: add regressions for reviewed edge cases
```
