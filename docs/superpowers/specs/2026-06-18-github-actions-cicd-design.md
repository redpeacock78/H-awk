# GitHub Actions CI/CD 設計書

**作成日**: 2026-06-18
**対象リポジトリ**: hawk
**ステータス**: draft

---

## 概要

hawk リポジトリに GitHub Actions による CI/CD パイプラインを導入する。
PR マージ前の品質ゲート（lint・クロスプラットフォームテスト）と、カバレッジの可視化（情報提供目的）を自動化する。

---

## スコープ

### 対象

- `.github/workflows/ci.yml` の新規作成（PR + master push CI）
- `scripts/awk-profile-to-lcov.sh` の新規作成（AWK カバレッジ変換スクリプト）
- `Makefile` への `GAWK_OPTS` 変数追加（最小修正）

### 対象外

- `.github/workflows/release-libs.yml` — 既存ワークフローが要件を満たしているため変更しない
- GitHub branch protection / ruleset の設定 — リポジトリオーナーが別途実施（後述）
- Codecov アカウントのセットアップ — リポジトリオーナーが別途実施

---

## トリガー

```yaml
on:
  pull_request:
    types: [opened, synchronize, reopened]
  push:
    branches: [master]
```

PR への push と master への直接 push の両方で動作する。
`pull_request` トリガーでは fork PR も含む（後述の fork 対応を参照）。

---

## ワークフロー設計

### ジョブ構成と依存関係

```
lint ─┬─► test (ubuntu-latest)  ─┐
      └─► test (macos-latest)   ─┴─► coverage (ubuntu-latest)
```

### Job 1: `lint`（ubuntu-latest）

静的解析を高速に実行し、後続ジョブのゲートとして機能させる。

**ShellCheck**

```bash
sudo apt-get update && sudo apt-get install -y shellcheck
find . -name '*.sh' -not -path './.git/*' | xargs shellcheck
shellcheck bin/hawk libexec/hawk libexec/hawk-*
```

`find` でリポジトリ内の `.sh` ファイルを列挙し、`bin/hawk` や `libexec/hawk*` のような拡張子なしスクリプトは個別に指定する。

**gawk lint**

```bash
sudo apt-get install -y gawk
make lint
```

**ワークフロー権限**

```yaml
permissions:
  contents: read
```

lint ジョブは読み取りのみ。書き込み権限は不要。

### Job 2: `test`（matrix: ubuntu-latest / macos-latest）

```yaml
needs: lint
```

| ステップ | ubuntu | macos |
|----------|--------|-------|
| gawk インストール | `sudo apt-get update && sudo apt-get install -y gawk curl` | `brew install gawk`（curl・make はプリインストール済み） |
| テスト実行 | `make test` | `make test` |

`make test` は `test-unit`・`test-dsl`・`test-e2e` を順に実行する。

**e2e テストの動作条件**

`tests/e2e/run.sh` は以下の手順でサーバーを操作する。

- ポート: 18180（`run.sh` 内で固定。変更するには `run.sh` の修正が必要）
- 起動: `./bin/hawk tests/e2e/fixtures/app.awk` をバックグラウンド起動後、`sleep` または接続リトライで待機
- 終了: `trap` による EXIT シグナルでサーバーを確実に停止

GitHub Actions のランナーはポート 18180 を使用しないため競合しない。
e2e 失敗時の診断のため、`server.log` を artifact として保存することを必須とする。

```yaml
- uses: actions/upload-artifact@v4
  if: failure()
  with:
    name: e2e-server-log-${{ matrix.os }}
    path: tests/e2e/server.log
```

**ワークフロー権限**

```yaml
permissions:
  contents: read
```

### Job 3: `coverage`（ubuntu-latest のみ）

```yaml
needs: test
```

matrix の全 test ジョブ（ubuntu + macos）通過後に起動する。
カバレッジは**情報提供目的**であり、merge のブロック条件にしない。
ジョブが失敗しても PR マージを妨げない（`continue-on-error: true`）。

**インストール**

```bash
sudo apt-get update && sudo apt-get install -y gawk kcov
```

**AWK カバレッジ（gawk --profile）**

```bash
mkdir -p coverage/awk
make test-unit GAWK_OPTS="--profile=coverage/awk/awk.prof"
scripts/awk-profile-to-lcov.sh coverage/awk/awk.prof > coverage/awk/awk.info
```

`test-unit` 内の gawk 呼び出しは1回のみ（Makefile の構造上）。
プロファイルファイルは `coverage/awk/awk.prof` に固定する。

**シェルスクリプトカバレッジ（kcov）**

```bash
mkdir -p coverage/shell
kcov --include-path=bin,libexec,scripts coverage/shell make test
```

AWK カバレッジ（`coverage/awk/`）とシェルカバレッジ（`coverage/shell/`）をディレクトリで分離することで、kcov がファイルを上書きするリスクを回避する。

**Codecov アップロード**

```yaml
env:
  CODECOV_TOKEN: ${{ secrets.CODECOV_TOKEN }}
steps:
  - uses: codecov/codecov-action@v4
    if: |
      env.CODECOV_TOKEN != '' &&
      (github.event_name != 'pull_request' ||
       github.event.pull_request.head.repo.full_name == github.repository)
    with:
      token: ${{ env.CODECOV_TOKEN }}
      files: coverage/awk/awk.info
      directory: coverage/shell
```

シークレットは job/step の `env:` に昇格させてから `if:` 条件で評価する。
これにより fork PR（`CODECOV_TOKEN` が空）とトークン未設定の両ケースを1つの条件で処理できる。

**ワークフロー権限**

```yaml
permissions:
  contents: read
  pull-requests: write  # Codecov PR コメント投稿に必要
```

---

## AWK カバレッジ変換スクリプト

### 設計方針

`gawk --profile` が出力するプロファイルファイル（`awkprof.out`）を解析し、
LCOV 形式（`SF:` / `DA:` / `end_of_record`）に変換する。
行番号マッピングはベストエフォートであり、Codecov の diff カバレッジ表示は参考値として扱う。

### 入力フォーマット（gawk profile）

```
# gawk profile, created ...

# Rule(s)

BEGIN {
     1      FS = ","
     3      print "start"
}

/pattern/ {
    42      process($0)
            # 実行されなかった行（カウントなし）
}
```

実行カウントは行頭のタブ区切り右詰め数値フィールドとして出力される。
カウントが存在しない行は未実行（DA:N,0）として扱う。

### 出力フォーマット（LCOV）

```
SF:hawk.awk
DA:10,1
DA:11,3
DA:15,42
DA:16,0
end_of_record
```

`SF:` パスはリポジトリルートからの相対パスとする。

**重要な制約**: `gawk --profile` は複数 `-f` ファイルを結合した出力を生成するが、
プロファイル内にソースファイル名のメタデータは含まれない。
`test-unit` は `hawk.awk`・プラグイン・`tests/unit/run.awk` を1プロセスで実行するため、
プロファイルはこれらを結合したビューになる。

このため、本スクリプトの `SF:` は `hawk.awk`（メインアプリケーションファイル）を単一エントリとして出力し、
ファイルをまたいだ行マッピングは行わない。カバレッジはファイル単位の集計率として提供し、
行レベルの diff カバレッジは実装上の目標としない。

### マッピングアルゴリズム

1. プロファイル内のブロック（`BEGIN`・`END`・ルール・関数）を順に走査する
2. 全ブロックを単一の `SF:hawk.awk` エントリにマッピングする
3. プロファイルの各行の実行カウントを `DA:` 行として出力する（行番号はプロファイルの連番を使用）
4. `LH:`（実行済みライン数）と `LF:`（総ライン数）を集計して出力する

Codecov の diff コメントは行番号精度に依存するが、本スクリプトはファイル単位のカバレッジ率の提供を目的とする。

### テスト用フィクスチャ

`scripts/tests/` に最低1件のフィクスチャを用意する。

- 入力: サンプル `awk.prof`（BEGIN + ルール + 関数を含む）
- 期待出力: 対応する `expected.info`
- 検証: `scripts/awk-profile-to-lcov.sh sample.prof | diff - expected.info`

---

## Makefile 修正

`test-unit` ターゲット内の gawk 呼び出しに `$(GAWK_OPTS)` を追加する。

```makefile
GAWK_OPTS ?=

test-unit:
    gawk -b $(GAWK_OPTS) ... -f hawk.awk ...
```

変更は1箇所のみ。`GAWK_OPTS` 未指定時の動作は現在と変わらない。
`release-libs.yml` は Zig ビルドのみであり、`GAWK_OPTS` の追加は release ジョブに影響しない。

---

## 依存ツール

**ubuntu-latest**

| ツール | 用途 | インストール |
|--------|------|-------------|
| ShellCheck | Bash 静的解析 | `apt-get install shellcheck` |
| gawk | AWK 実行・lint・profile | `apt-get install gawk` |
| kcov | シェルスクリプトカバレッジ | `apt-get install kcov` |
| curl | e2e テスト | `apt-get install curl` |

**macos-latest**

| ツール | 用途 | インストール |
|--------|------|-------------|
| gawk | AWK 実行 | `brew install gawk` |
| curl | e2e テスト | プリインストール済み |
| make | ビルド | プリインストール済み |

ShellCheck・kcov は ubuntu 専用（lint/coverage ジョブのみ）。

---

## branch protection 設定（実装スコープ外）

本ワークフロー単体では PR マージをブロックしない。
マージブロックを有効にするには、リポジトリオーナーが以下を設定する必要がある。

- Settings → Branches → Branch protection rules → `master`
- Required status checks: `lint`・`test (ubuntu-latest)`・`test (macos-latest)`
- `coverage` は required check に含めない（`continue-on-error: true` のため）

---

## 成功条件

- PR に対して lint・test（ubuntu/macos 両方）・coverage の3ジョブが自動実行される
- lint または test が失敗した PR は（branch protection 設定後に）マージブロックされる
- coverage ジョブの失敗は PR マージをブロックしない
- Codecov の PR コメントにカバレッジ率が表示される（diff カバレッジは参考値）
- fork PR でも lint・test は実行される（Codecov アップロードはスキップ）
- master への push でも同じパイプラインが動作する

---

## リリースワークフローとの関係

`release-libs.yml`（タグ push → Zig クロスコンパイル → GitHub Release）は既存のまま維持する。
CI ワークフローとリリースワークフローは独立しており、相互に干渉しない。
Makefile への `GAWK_OPTS ?=` 追加は release ジョブに影響しない（Zig ビルドは gawk を使用しない）。
