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

`http_parser.zig` に `parseFrameResult` 構造体を追加し、フレーミング判定を一箇所に集約する。
`parseFrameResult` は以下のフィールドを持つ。

- `complete_len: usize` — 現在のバッファで消費するバイト数（完全なリクエスト 1 件分）
- `action: enum { enqueue, wait, error_response, close }`

`event_loop.zig` は `complete_len` バイトだけバッファから取り除き、残余バイトはそのまま保持する。

リクエストが完了したとみなす条件は以下の 3 つをすべて満たすこととする。

1. ヘッダー終端子 `\r\n\r\n` がバッファに存在する。
2. `Content-Length` の有無を確定済みである（存在すること、または存在しないことが確認されていること）。
3. バッファが `header_end + 4 + content_length` バイト以上のデータを保持している。

`Content-Length` が存在しないリクエストは、ボディ長を 0 として扱う（action: enqueue）。
`Content-Length` の値が数値として解析できない場合は `400 Bad Request` を返す（action: error_response）。
`Content-Length` が負の値または `+` や空白プレフィックスを含む場合も `400 Bad Request` を返す（action: error_response）。
同一リクエストに `Content-Length` が複数存在する場合、または値が相互に矛盾する場合も `400 Bad Request` を返す（action: error_response）。
`Content-Length` が最大ボディサイズ（デフォルト 1 MiB = 1048576 バイト）を超える場合は `413 Content Too Large` を返す（action: error_response）。
最大ボディサイズはコンパイル時定数 `MAX_BODY_SIZE` として `event_loop.zig` に定義する。

ヘッダー名の比較はすべて case-insensitive（`content-length`, `Content-Length`, `CONTENT-LENGTH` を同一視）で行う。
ヘッダー値の前後の OWS（optional whitespace）は RFC 7230 に従いトリムする。

`Transfer-Encoding: chunked` はサポート対象外とし、`501 Not Implemented` を返してから接続を閉じる（action: close）。
`Transfer-Encoding` と `Content-Length` が同時に存在する場合、RFC 7230 §3.3.3 に従い `Content-Length` を無視して `Transfer-Encoding` 優先とし、`chunked` なら `501` を返して接続を閉じる。

Keep-alive に対応するため、1 バッファに複数の完全なリクエストが含まれる場合は以下の処理とする。

1. `parseFrameResult.complete_len` バイトだけバッファから取り除いてリクエストをエンキューする。
2. 残余バイトを接続の読み取りバッファに保持する。
3. 次のループ / 読み取りで残余バイトを再度 `parseFrameResult` に通す。

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

テストはネットワーク層の分割送信を再現するため、`curl` ではなく raw ソケットで実装する。
`Content-Length` 不正値（負数、非数値、1 MiB 超）に対して正しいステータスを返すことも検証する。

---

### P0-2: DSL シグネチャとランタイムの arity 不整合修正

#### 問題

一部の API において、ランタイムのディスパッチテーブル、`dsl/sig.awk`、README ドキュメントの 3 者間で arity が一致していない。
既知の不整合は以下のとおりである。

- `hawk.app.on`: ランタイムは 3 引数（method, path, handler）だが、DSL シグネチャは 2 引数
- `ctx.res.redirect`: ランタイムは 2 引数（url, code）をサポートするが、DSL シグネチャは 1 引数のみ
- `safe.html.fragment`: README は可変長引数と説明しているが、ランタイムは 3 引数のみ受け付ける

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

**`hawk.app.on`** および **`ctx.res.redirect`** のオプション引数は、DSL デシュガー時に正規化する。
`ctx.res.redirect(url)` は `ctx.res.redirect(url, 302)` にデシュガーする。
既存のディスパッチャーは arity 0〜3 の固定テーブルで動作するため、正規化後の 2 引数呼び出しとして扱う。

**`safe.html.fragment`** は可変長引数に対応する。
実装方法は `safe.html.fragment` 専用のスペシャルケースとし、汎用的な `hawk_dispatch::callv` は導入しない。

デシュガーの生成規則は以下のとおりである。

- 引数 0〜3 個：既存のディスパッチャー（`hawk_dispatch::call0`〜`call3`）をそのまま使う。
- 引数 4 個以上：引数を AWK 配列 `_ds_frag_args` に格納し、`safe::fragment_v(_ds_frag_args, n)` を呼び出す特殊ディスパッチに展開する。

`safe::fragment_v(arr, n)` は `core/safe.awk` に追加するランタイム関数であり、`arr[1]`〜`arr[n]` を連結して返す。

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

---

### P0-3: TSV ストレージへの書き込みロック追加

#### 問題

TSV ヘルパー関数は複数ワーカーによる同時書き込みに対して安全でない。
具体的な危険性は以下のとおりである。

- `append_tsv` はロックなしで追記する。
- `delete_tsv` と `update_tsv` は固定のパス `path ".tmp"` を一時ファイルに使用しており、複数ワーカーが同一パスを競合して書き込む。
- `libs/net` が存在する場合はマルチワーカーモードが有効になるため、デモアプリの `data/todos.tsv` が破損するリスクがある。

#### 要求仕様

ロック機構は `scripts/tsv-lock.sh` として事前に実装した固定シェルスクリプトに委譲する。
AWK がデータをシェルに渡す際に動的なスクリプト生成は行わない（シェルインジェクション防止）。

**`scripts/tsv-lock.sh` の仕様:**

```sh
# 使用方法
scripts/tsv-lock.sh lock   <lockfile>   # ロック取得、成功=0, 失敗=1
scripts/tsv-lock.sh unlock <lockfile>   # ロック解放
```

データの受け渡しは stdin / stdout / 環境変数を使わず、AWK 側が読み取りと書き込みを直接行う。
ロックの役割はクリティカルセクションの排他制御のみとし、データ変換はすべて AWK 側で実施する。

**ロック取得の実装（`scripts/tsv-lock.sh lock <lockfile>`）:**

`flock` が利用可能な場合は `flock -xn "$lockfile"` で排他ロックを取得し、取得後に 0 を返してプロセスを継続させる。
`flock` が利用できない場合は `mkdir "$lockfile.dir"` のアトミック成功 / 失敗でロックを判定する。
リトライは `sleep 0.1` × 50 回（合計 5 秒）。`sleep 0.1` が利用できない環境（古い sleep）では `sleep 1` × 5 回にフォールバックする。

**スタールロックの検出:**
`mkdir` 方式の場合のみ適用する。ロックディレクトリ内に PID ファイル（`pid` という名前）を置き、PID のプロセスが生存していない（`kill -0 <pid>` が失敗する）場合にスタールロックと判定して削除する。
30 秒 mtime ルールは使用しない（実行時間が長い書き込みを誤って割り込む危険があるため）。

**ロック取得失敗時の動作:**
タイムアウトした場合は書き込みを中断し、呼び出し元の AWK 関数に `-1` を返す。

**一時ファイルのパス:**
`srand(PROCINFO["pid"] + systime())` を `BEGIN` ルールで必ず実行する。
テンポラリファイルのパスは以下の形式とする。

```
path ".tmp." PROCINFO["pid"] "." systime() "." int(rand() * 1000000)
```

`mv` の戻り値（`system()` の戻り値）を確認し、失敗した場合はテンポラリファイルを `system("rm -f " tmppath)` で削除してエラーを返す。

**シェルメタキャラクター対応:**
`path` は AWK 変数であり、シェルコマンドに渡す前に `scripts/tsv-lock.sh` が `$1` として受け取る。
スクリプト内でパスを `"$1"` とクォートして使用する。
スペース、引用符、セミコロン、改行、グロブを含むパスのテストを追加する。

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
- 複数行にまたがる文字列連結
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
適用対象は以下のとおりである。

- `ctx::query`
- `ctx::param`
- `ctx::get_header`
- `ctx::req_form`
- `ctx::req_json`

`ctx::body` については以下のセマンティクスを明示する。
ハンドラーが呼び出される時点でリクエストは必ず完全に受信済みである（P0-1 で保証）。
`Content-Length: 0` の場合、またはボディ区切り後のバイト列が 0 バイトの場合は `ok("")` を返す。

`ctx::req_json` の `ParseError` 条件を `ctx::body` の空 / 欠損とは明確に分離する。
- `ctx::body` は常に `ok(...)` を返す（受信済みが保証されているため）。空ボディは `ok("")` を返す。
- `ctx::req_json` は JSON パースに失敗した場合のみ `ParseError` を返す。`Content-Type: application/json` + 空ボディは `ctx::req_json` が `ParseError` を返すが、`ctx::body` は `ok("")` を返す。
- この 2 者の動作は独立しており、`ctx::body` の返値が `ctx::req_json` の動作に影響しない。

#### 変更対象ファイル

- `core/ctx.awk`
- `tests/unit/test_ctx.awk`
- `tests/unit/test_request.awk`

#### 追加するテスト

- 空値を持つクエリパラメータが `ok("")` を返すこと（`?key=` の形式）。
- 空値を持つフォームフィールドが `ok("")` を返すこと（`key=` の形式）。
- 欠損キーが `ParseError` を返すこと。
- 空ボディ（`Content-Length: 0`）が `ok("")` を返すこと。

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

- `isarray(val)` が真：既存の `json_encode(val)` に委譲する
- `typeof(val) == "number"`：JSON 数値（クォートなし）に変換する
- `typeof(val) == "strnum"`（数値として解釈可能な文字列、例: `"42"`, `"001"`, `"1e2"`）：JSON 文字列として扱う（クォートあり）。AWK の `strnum` は文字列として渡されたものであり、呼び出し元が数値として意図した場合は `typeof` で区別できないためである。
- それ以外（通常の文字列）：JSON 文字列（`"..."` 形式、`\"`・`\\`・`\n`・`\r`・`\t`・制御文字をエスケープ）に変換する
- `null`・真偽値は AWK の型システムに存在しない。`"null"`・`"true"`・`"false"` は文字列として JSON 文字列に変換する。

追加するテストは以下のとおりである。
- AWK 配列（オブジェクト形式）が JSON オブジェクトに変換されること。
- 整数リテラル `42` が `42` に変換されること（クォートなし）。
- 文字列 `"42"` が `"42"` に変換されること（クォートあり）。
- 浮動小数点 `3.14` が `3.14` に変換されること。
- 空文字列 `""` が `""` に変換されること。
- エスケープが必要な文字列（ダブルクォート、バックスラッシュ、改行）が正しく変換されること。
- 空配列 `[]` / ネストした配列が正しく変換されること。

事前エンコード済みの JSON 文字列を直接セットするためのヘルパーとして `ctx.res.json_raw(str)` を追加する。

この変更は破壊的変更である。`ctx.res.json` に pre-encoded JSON 文字列を渡している既存コードはすべて二重エンコードになる。
修正対象のファイルは以下のとおりである（すべて確認・修正すること）。

- `app.awk`
- `tests/e2e/fixtures/app.awk`
- `tests/unit/test_ctx.awk` 内の既存テスト

#### 変更対象ファイル

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

バリデーションは `_DS_match_ng_is_default` フラグを利用せず、アームの型付き / 非型付きを直接判定する方式で実装する。

アームの有効な順序は以下の規則に従う（Result 式と Option 式は別々の規則を持つ）。

**Result 式の有効なアーム順序:**
- `ok [bind]` アームは最初に置く（複数可、順序任意）
- 型付き `ng e<Type>:` アームは `ok` の後、catch-all の前に置く（順序任意）
- catch-all（`ng:`, `ng err:`, `default:`, `default err:`）は必ず最後の 1 つだけ

無効なパターン：
- catch-all の後に型付き `ng e<Type>:` が続く → エラー
- 重複した catch-all → エラー
- Result 式に `none:` が含まれる → エラー

**Option 式の有効なアーム順序:**
- `ok [bind]:` アームを最初に置く
- `none:` は最後の catch-all として 1 つだけ許可

無効なパターン：
- `none:` の後にアームが続く → エラー
- Option 式に `ng e<Type>:` が含まれる → エラー
- `ok` アームが存在しない（`none:` のみ）→ エラー

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

テンプレートパスをランタイムで検証し、以下のパスのみを許可する。

- `views/` プレフィックスで始まる相対パス

以下のパスは拒否してエラーレスポンス（500）を返す。

- 絶対パス（`/` で始まるパス）
- `..` を含むパス
- 空文字列

パス正規化は以下の方法で行う。

```awk
cmd = "realpath -- " shell_quote(path) " 2>/dev/null"
ret = (cmd | getline normalized)
close(cmd)
if (ret != 1) {
    # realpath が利用できない、またはパスが存在しない
    return render_error(500, "template path could not be verified")
}
```

ベースディレクトリは `ENVIRON["PWD"]` ではなく、hawk 起動時に確定する信頼済みの定数 `HAWK_TEMPLATE_ROOT`（`views/` の絶対パス）を使う。
`HAWK_TEMPLATE_ROOT` は `bin/hawk` がプロセス起動時に環境変数として設定し、`core/template.awk` はこれを参照する。

`realpath` が利用できない環境（戻り値 `!= 1`）では fail-closed とし、`500 Internal Server Error` を返す。
シンボリックリンクの許容は `realpath` 正規化後のパスが `HAWK_TEMPLATE_ROOT` 配下に収まることで保証する。

長期的な設計として `TemplatePath` ブランド型の導入を検討するが、本フェーズでは短期的なランタイムチェックのみを実装する。

#### 変更対象ファイル

- `core/template.awk`
- `core/response.awk`
- `core/ctx.awk`
- `dsl/sig.awk`
- `README.md`
- `tests/unit/test_template.awk`

#### 追加するテスト

- `ctx.res.render("views/index.html")` が成功すること。
- `ctx.res.render("../secret")` が失敗すること。
- 絶対パスが失敗すること。
- 空文字列が失敗すること。

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
この関数が存在しない場合は `core/adt.awk` に追加する。
デシュガーが生成するコードは `result_err_type` を呼び出してマッピングテーブルを参照するパターンを使う。

追加するテストは以下のとおりである。
- `ParseError` を含む `Result ng` が `?=` で 400 に変換されること。
- `AuthError` を含む `Result ng` が `?=` で 401 に変換されること。
- 未知のエラー型が `?=` で 500 に変換されること。
- `Option none` が `?=` で 404 に変換されること（従来動作の確認）。

将来的には `let body ?= ctx.req.json() else 400` のような構文拡張を検討する。

#### 変更対象ファイル

- `dsl/desugar_nullcoalesce.awk`
- `core/adt.awk`（`result_err_type` 追加）
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

`validator` によるバリデーション失敗の表現は DSL 型エラーとする。
`Untrusted<T>` を `validator` 関数に渡した場合、戻り値の型は `T` として扱われる。
検証ロジック自体が失敗する（`Result<T, E>` を返す）場合は、`classifier: validator` ではなく通常の関数として実装する。

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
代わりに新規追加する `type::assert_accepts(val, "TypeName")` を呼び出すランタイムアサーションヘルパーを生成する。
既存の `type::accepts(val, typename)` は boolean を返す互換チェック関数であり、上書きしない。

`type::assert_accepts` の契約は以下のとおりである。

- 引数：値と型名文字列
- 戻り値：型が一致する場合は `val` をそのまま返す
- 型不一致の場合：`_hawk_fatal` でランタイムエラーを出力して終了する
- ブランド型への強制変換は `type::assert_accepts` でも行わない
- 内部で `type::accepts(val, typename)` を呼び出して判定する

**`type::accepts` の対応型の監査と補完:**
実装前に `dsl/type.awk` 内の `type::accepts` が以下のすべての型を正しく処理することを確認する。
対応していない型がある場合は `type::accepts` を先に修正し、その変更を本 P2-3 タスクに含める。

確認対象の型ファミリー：
- プリミティブ（`Int`, `Float`, `Str`, `Bool`）— 既存
- union 型（`A | B`）
- alias 型（`type Foo = Bar`）
- ブランド型（`brand Foo(Str)`）— accepts は構造チェックのみで強制変換しない
- `Option<T>`
- `Result<T, E>`
- `Effect<T>`

静的型チェックで代入の型整合性が確定している場合は `type::assert_accepts` の呼び出し自体を省略する。
「確定」の条件：DSL の型チェックフェーズがエラーなく通過し、かつ両辺の型が同一である場合。

#### 変更対象ファイル

- `dsl/desugar_let.awk`
- `dsl/type.awk`（`type::assert_accepts` 追加）
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

`response_wire` を呼び出す前のプリフライト検証として、すべてのヘッダー名を以下の正規表現で検証する。
プリフライトとして実装するため、いずれかのヘッダーが無効な場合はバイトを一切出力しない。

```
^[!#$%&'*+.^_`|~0-9A-Za-z-]+$
```

無効なヘッダー名が検出された場合は、元の `res` 配列とは独立したフレッシュなオブジェクトから `500 Internal Server Error` レスポンスを構築して出力する。
これにより、汚染された `res` 配列の内容が部分的に出力されることを防ぐ。
警告ログをエラー出力（stderr）に出力する。

「無視」ではなく「拒否（500 返却）」とする理由は、無効なヘッダー名がサイレントに欠落すると API の呼び出し元がデバッグできないためである。

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
関数の存在確認には gawk の `@include` 後に `(funcname) in FUNCTAB` で検証する。

#### 変更対象ファイル

- `core/plugin.awk`
- `libexec/hawk-libs`

#### 追加するテスト

- `manifest.awk` が存在しないプラグインディレクトリがスキップされ、警告が出力されること。
- `manifest.awk` は存在するが `plugin_<name>_manifest` 関数が未定義のプラグインがスキップされ、警告が出力されること。
- 有効な `manifest.awk` を持つプラグインが正常にロードされること（回帰テスト）。

---

## Phase 4: README 更新

Phase 1〜3 の実装完了後、`README.md` を以下の観点で更新する。

1. H-awk のアーキテクチャを明示する（CLI ラッパー、libexec サブコマンド、DSL プリプロセッシング、gawk ランタイム、オプションの Zig ライブラリの関係）。
2. TSV ストレージのロック実装（`flock` / `mkdir` フォールバック）を説明し、マルチワーカーでの利用条件を明示する。
3. `ctx.res.json` が AWK 配列と値を JSON エンコードすること、および `ctx.res.json_raw` が事前エンコード済み文字列用であることを説明する。
4. `safe.html.fragment` が可変長引数を受け付けることを明示する。
5. `render()` が `views/` 配下のパスのみを許可すること、および `realpath` が利用できない環境ではシンボリックリンクによる制限回避の可能性があることを注記する。
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
- `libs/net` が `Transfer-Encoding: chunked` に対して `501` を返し接続を閉じること。
- `ctx.req.form("x")` が `x=` に対して `ok("")` を返すこと。
- `ctx.res.json(data)` が AWK 配列を JSON エンコードすること。
- `when` アーム内のパイプ右辺の dot 記法が正しくデシュガーされること。
- 文字列内の波括弧が関数境界の解析を壊さないこと。
- TSV ストレージがロックによって安全に使用できること。
- 無効なレスポンスヘッダー名が拒否されること。
- `ctx.res.render("../secret")` が失敗すること（path traversal 保護）。
- `?=` が `ParseError` を 400 に、`AuthError` を 401 に、未知エラーを 500 にマッピングすること。
- `classify: validator` 関数が `Untrusted<T>` から `T` にアンラップすること。
- 複合型再代入が `type::coerce` を使わないこと。
- プラグイン探索が `manifest.awk` 欠落または関数未定義のディレクトリをスキップすること。
- README が実際の動作と一致していること。

---

## コミット分割方針

以下の順序でコミットを分割する（フェーズ順に対応）。

```
fix(net): wait for complete content-length body before enqueue
fix(net): return 501 and close connection for chunked encoding
fix(dsl): align signature arities with runtime dispatch
fix(tsv): add flock-based write locking with mkdir fallback
fix(dsl): ignore braces inside strings and comments
fix(ctx): distinguish missing request keys from empty values
fix(ctx): encode data in ctx.res.json, add json_raw helper
fix(dsl): transform pipe preludes inside when arms
fix(dsl): reject catch-all when arms before typed arms
fix(template): restrict render path to views/ directory
fix(response): reject invalid header names
fix(dsl): fix validator classify to unwrap Untrusted
fix(dsl): avoid type::coerce for complex type reassignment
fix(dsl): improve ?= error type mapping with type-based defaults
fix(plugin): tolerate missing manifest in plugin discovery
docs: clarify storage, json, render, and DSL semantics
test: add regressions for reviewed edge cases
```
