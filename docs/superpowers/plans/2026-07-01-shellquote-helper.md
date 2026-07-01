# `_shellquote` ヘルパを util 層に据える実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `serve_static()` から呼び出される `_shellquote()` を、共通ユーティリティ層である `core/util.awk` に定義し直し、`core/tsv.awk` への暗黙依存を切る。

**Architecture:** 現状 `_shellquote()` は `core/tsv.awk` の末尾（281–284 行）に定義され、`core/static.awk:66` および `core/tsv.awk` 内の複数箇所から共有されている。両者は同じデフォルト namespace（`awk`）に属するため gawk 上では動作するが、この配置は「TSV I/O の内部ヘルパ」を全体で流用している状態にあたり、`tsv.awk` の改変や `@include` 順序の変更で `static.awk` 側が壊れる。定義を `core/util.awk` に移し、`tsv.awk` の重複定義を削除する。

**Tech Stack:** gawk 5.x、既存の `tests/unit/` ランナー（`bash scripts/test.sh unit` 相当）。

## Global Constraints

- gawk 5.0 以降を対象とする。既存の `@namespace` 指定は変更しない。
- 追加する関数は既存のユーティリティ命名（`_util_init`、`url_decode` など）と同じ default namespace に置く。
- テストは `tests/unit/run.awk` から呼び出されるフラットな `test_*` 関数として追加する。
- 修正コミットは genshijin-commit スタイル。件名は 50 文字以内。Conventional Commits の type は `fix`（動作の破損経路を塞ぐため）。

---

## File Structure

| ファイル | 役割 |
| --- | --- |
| `core/util.awk` | `_shellquote(s)` の新規定義を追加。 |
| `core/tsv.awk` | 末尾の `_shellquote()` 定義を削除。呼び出し側（`_shellquote(tmppath)` など）は同名で引き続き成立する。 |
| `core/static.awk` | 変更なし。 |
| `tests/unit/test_util.awk` | `_shellquote` の単体テストを追加。境界条件を網羅する。 |
| `tests/unit/test_static.awk` | `serve_static()` 経由でシェルメタ文字を含むパスが安全に扱えることを検証する end-to-end テストを追加。 |
| `tests/unit/run.awk` | 追加した `test_*` を BEGIN 内で呼び出す。 |

## Task 1: `_shellquote` を util.awk に移し、境界条件と serve_static 経路を固定する

**Files:**
- Modify: `core/util.awk`（末尾に関数を追加）
- Modify: `core/tsv.awk:281-284`（重複定義を削除）
- Modify: `tests/unit/test_util.awk`（`_shellquote` 単体テストを追加）
- Modify: `tests/unit/test_static.awk`（`serve_static()` 経由テストを追加）
- Modify: `tests/unit/run.awk`（テスト呼び出しを追加）

**Interfaces:**
- Consumes: なし（既存呼び出し側は同名で引き続き成立）。
- Produces:
  - `_shellquote(s)` → シングルクォート囲みの POSIX sh 用にエスケープされた文字列を返す。空文字入力に対しては `''` を返す。シングルクォートは `'\''` にエスケープされる。それ以外の文字（改行、タブ、バックスラッシュ、`$`、バッククォート、glob、チルダ、波括弧など）はそのままシングルクォート内に置く。

- [ ] **Step 1: テスト関数と呼び出しを追加する（この時点では既存定義があるため GREEN）**

`tests/unit/test_util.awk` の末尾に単体テストを追加する。

```awk
function test_util_shellquote_plain() {
  assert_eq(_shellquote("hello"),      "'hello'",      "util: shellquote plain")
  assert_eq(_shellquote(""),           "''",           "util: shellquote empty")
  assert_eq(_shellquote("with space"), "'with space'", "util: shellquote space")
}

function test_util_shellquote_single_quote() {
  assert_eq(_shellquote("a'b"),   "'a'\\''b'",   "util: shellquote single quote")
  assert_eq(_shellquote("'"),     "''\\'''",     "util: shellquote only quote")
  assert_eq(_shellquote("a''b"),  "'a'\\'''\\''b'", "util: shellquote consecutive quotes")
}

function test_util_shellquote_shell_meta() {
  assert_eq(_shellquote("$(rm -rf /)"), "'$(rm -rf /)'", "util: shellquote command substitution")
  assert_eq(_shellquote("a;b|c&d"),     "'a;b|c&d'",     "util: shellquote metachars")
  assert_eq(_shellquote("a`b`c"),       "'a`b`c'",       "util: shellquote backtick")
  assert_eq(_shellquote("$HOME"),       "'$HOME'",       "util: shellquote variable")
}

function test_util_shellquote_whitespace_and_backslash() {
  assert_eq(_shellquote("a\nb"), "'a\nb'", "util: shellquote newline")
  assert_eq(_shellquote("a\tb"), "'a\tb'", "util: shellquote tab")
  assert_eq(_shellquote("a\\b"), "'a\\b'", "util: shellquote backslash")
}

function test_util_shellquote_glob_and_expansion() {
  assert_eq(_shellquote("*.txt"),   "'*.txt'",   "util: shellquote glob star")
  assert_eq(_shellquote("a?b"),     "'a?b'",     "util: shellquote glob question")
  assert_eq(_shellquote("[abc]"),   "'[abc]'",   "util: shellquote glob bracket")
  assert_eq(_shellquote("~/x"),     "'~/x'",     "util: shellquote tilde")
  assert_eq(_shellquote("{a,b}"),   "'{a,b}'",   "util: shellquote brace")
}
```

`tests/unit/test_static.awk` の末尾に `serve_static()` end-to-end テストを追加する。fixture は AWK のリダイレクトで直接作り、シェルを介さない（本体 `_shellquote` と同じアルゴリズムをテスト側に置くと独立オラクルにならないため）。ファイル名にはスペース・シングルクォート・`$`・バッククォート・波括弧・glob 文字に加え、副作用検出用のコマンド置換 `$(touch /tmp/hawk_pwn_marker_$$)` を埋め込む。`_shellquote` が正しく効いていればマーカーは作られない。fixture はプロセス ID を混ぜたユニーク名にし、テスト開始前後で必ず削除する。

```awk
function test_static_serve_shell_metachars(   pubdir, fname, fpath, marker, req, res, ok) {
  pubdir = "public"
  system("mkdir -p " pubdir)

  # 副作用検出用マーカー。事前に消しておく。
  marker = "/tmp/hawk_pwn_marker_" PROCINFO["pid"]
  system("rm -f " marker)

  # スペース、シングルクォート、$、バッククォート、波括弧、glob 文字に加え、
  # 実行されれば marker を作るコマンド置換を埋め込む。
  fname = "sq test '$(touch " marker ")`x`{a,b}*_" PROCINFO["pid"] ".txt"
  fpath = pubdir "/" fname

  # fixture 生成はシェルを介さず AWK のリダイレクトで行う。
  print "ok" > fpath
  close(fpath)

  delete req; delete res
  req["method"] = "GET"
  req["path"]   = "/" fname

  ok = serve_static(req, res)
  assert_eq(ok, 1,                              "static: serve_static returns 1 for meta path")
  assert_eq(res["status"], 200,                 "static: serve_static status 200 for meta path")
  assert_eq(res["body"],   "ok\n",              "static: serve_static body for meta path")

  # 副作用検出: コマンド置換が実行されると marker が残る。
  assert_true((system("test ! -e " marker) == 0), \
              "static: no command substitution side effect")

  # 後始末（assertion で早期 fatal しても marker 消去は次回実行で救う）。
  system("rm -f " marker)
  # ファイル削除もシェルを介さない安全な経路を通す（本体 _shellquote 経由）。
  system("rm -f -- " _shellquote(fpath))
}
```

fixture の本文末尾に `\n` が付くのは AWK の `print` 仕様。`res["body"]` 期待値も `"ok\n"` に合わせる。

`tests/unit/run.awk` の `test_util_log_warn()` の直後、および `test_static_read()` の直後にそれぞれ呼び出しを追加する。

```awk
  test_util_shellquote_plain()
  test_util_shellquote_single_quote()
  test_util_shellquote_shell_meta()
  test_util_shellquote_whitespace_and_backslash()
  test_util_shellquote_glob_and_expansion()
```

```awk
  test_static_serve_shell_metachars()
```

Run:
```
make test-unit 2>&1 | tail -60
```

想定: この時点では `core/tsv.awk` に既存定義があるため、単体テスト側は **PASS**。`serve_static()` end-to-end テストも既存 `_shellquote` で PASS する。新規テストが正しく呼び出されている（skip されていない）ことだけをここで確認する。

補足: gawk は `hawk.awk` 経由で全 `@include` を先にパースしてから BEGIN を実行する。よって `core/tsv.awk` の末尾定義と `core/util.awk` の先頭 BEGIN のどちらでも、BEGIN 実行時点では `_shellquote` は解決済みになる。この前提が Step 1 の GREEN を成立させている。

- [ ] **Step 2: `core/tsv.awk` から `_shellquote` 定義を削除して RED を作る**

`core/tsv.awk` の 281–284 行を削除する。

削除前:
```awk
function _shellquote(s) {
  gsub(/'/, "'\\''", s)
  return "'" s "'"
}
```

削除後: 該当行は空となる（末尾の空行のみ残す）。

Run:
```
make test-unit 2>&1 | tail -60
```

想定: gawk は最初に `_shellquote` を呼ぶ TSV 系テスト（`test_tsv_delete_update` など）で `fatal: function '_shellquote' not defined` を出してプロセスごと落ちる。よって static 系テストはこの状態では実行されない。RED 判定はこの fatal 一本で足り、追加した `serve_static` テストが同時に走らないことは想定内である。ここで初めて「新しい util 層の定義が無いと壊れる」ことが担保される。

- [ ] **Step 3: `core/util.awk` に `_shellquote` を追加して GREEN に戻す**

`core/util.awk` の末尾（`_all_impl` 関数の後ろ）に以下を追加する。File Structure（ファイル冒頭表）の「末尾に関数を追加」記載と一致させる。

```awk
function _shellquote(s) {
  gsub(/'/, "'\\''", s)
  return "'" s "'"
}
```

併せて、ファイル冒頭の関数一覧コメント（4–13 行目）に一行追加する。

```awk
#   _shellquote(s)         -- POSIX sh 用にシングルクォート囲みでエスケープ
```

Run:
```
make test-unit 2>&1 | tail -60
```

想定: 追加した単体テスト 5 件と `serve_static()` end-to-end テスト 1 件を含めて全テスト PASS。`tsv` / `static` 系の既存テストも通ること。

- [ ] **Step 4: コミット**

genshijin-commit スタイル（type(scope): 動詞開始、件名 50 文字以内、body に「なぜ」）。type は `fix`（#43 は bug ラベル、動作破損経路の修理として PATCH 相当）。

```bash
git add core/util.awk core/tsv.awk tests/unit/test_util.awk tests/unit/test_static.awk tests/unit/run.awk
git commit -m "$(cat <<'EOF'
fix(core): move _shellquote to util

serve_static がヘルパを util 経由で参照する構成に統一。
tsv.awk 内 private 定義への暗黙依存を切り、include 順や
tsv リファクタで static が壊れる経路を除去。

境界条件テスト追加: 空文字、空白、シングルクォート連続、
コマンド置換、シェルメタ文字、バッククォート、変数展開、
改行、タブ、バックスラッシュ、glob、チルダ、波括弧。
serve_static() end-to-end テストで実際にシェルへ渡っても
副作用が起きないことを固定。

Closes #43
EOF
)"
```

---

## Self-Review

- 仕様の網羅: issue #43 の期待挙動（`GET /some-existing-static-file` が undefined-function で落ちない、スペースやシェル特殊文字を含むパスも安全に扱われる、path traversal は 404/400 系で失敗する）は、既存 `test_static_safe_path` がパストラバーサル分を担保し、本計画で追加する `_shellquote` 単体テスト 5 件と `test_static_serve_shell_metachars` がクォート境界と end-to-end 経路を担保する。
- TDD 順序: Step 1 で先にテスト呼び出しを追加し、Step 2 で既存定義を削除して初めて RED を作る。RED は「関数未定義」による fatal で、テスト設計上の意図と一致する。Step 3 の util.awk 追加でのみ GREEN に戻る。テストが「消しても通る」偽 RED 経路は存在しない。
- プレースホルダ: なし。全ステップに具体的なコード、コマンド、想定出力を記載した。
- 型・命名の一貫性: 追加する関数名 `_shellquote(s)` は既存呼び出し側（`core/static.awk:66`、`core/tsv.awk:182,213,240,276`）と完全に一致する。
- 副作用検出: `serve_static()` テストは `$(echo pwn)` のコマンド置換が実行されると副作用マーカーを残す設計にし、`assert_true(system("test ! -e /tmp/hawk_pwn_marker") == 0)` で明示的に「副作用が発生していないこと」を検証する。

## Notes

`core/mailbox.awk` の `mailbox::shell_quote()` は `@namespace "mailbox"` 下の独立した関数であり、本計画の対象外。default namespace の `_shellquote` と衝突しない。

## Deferred / 別 issue

以下は本計画のスコープ外。必要なら別 issue として立てる。

- `hawk.awk` が全 `@include` を先にパースして BEGIN を実行する単一エントリ運用であることは、本計画の GREEN 判定の前提になっている。この前提が将来崩れる（複数エントリ、`@include` の遅延ロード等）場合、`core/util.awk` を `core/tsv.awk` より先にロードする順序制約を明示する必要がある。
- 本計画の `_shellquote` は NUL バイトを含まない入力を前提とする。gawk の文字列は NUL を扱えないため、`req["path"]` が NUL を含む状況は上流で弾かれている想定。NUL 境界の扱いは別 issue。
- 上流でパスをサニタイズし、そもそも shell へ渡さない構成（`system()` 経由の `mv` を廃し AWK ネイティブ or gawk extension で完結させる）は、本 issue #43 の範囲を超えるアーキテクチャ変更。別 issue で扱う。
