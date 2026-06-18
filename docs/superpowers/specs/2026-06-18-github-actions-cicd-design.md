# GitHub Actions CI/CD 設計書

**作成日**: 2026-06-18
**対象リポジトリ**: hawk
**ステータス**: draft

---

## 概要

hawk リポジトリに GitHub Actions による CI/CD パイプラインを導入する。
PR マージ前の品質ゲートとして、静的解析・クロスプラットフォームテスト・カバレッジ計測を自動化する。

---

## スコープ

### 対象

- `.github/workflows/ci.yml` の新規作成（PR CI）
- `scripts/awk-profile-to-lcov.sh` の新規作成（AWK カバレッジ変換スクリプト）
- `Makefile` への `GAWK_OPTS` 変数追加（最小修正）

### 対象外

- `.github/workflows/release-libs.yml` — 既存ワークフローが要件を満たしているため変更しない
- Codecov アカウントのセットアップ（リポジトリオーナーが別途実施）

---

## ワークフロー設計

### トリガー

```yaml
on:
  pull_request:
    types: [opened, synchronize, reopened]
  push:
    branches: [master]
```

PR への push と master への直接 push の両方で動作させる。

### ジョブ構成

#### Job 1: `lint`（ubuntu-latest）

静的解析を高速に実行し、後続ジョブのゲートとして機能させる。

| ステップ | 内容 |
|----------|------|
| ShellCheck | `bin/hawk`, `libexec/hawk*`, `tests/**/*.sh`, `scripts/*.sh` に対して実行 |
| gawk lint | `make lint`（`gawk --lint` による AWK 構文チェック） |

#### Job 2: `test`（matrix: ubuntu-latest / macos-latest）

`needs: lint` — lint 通過後に起動する。

| ステップ | ubuntu | macos |
|----------|--------|-------|
| gawk インストール | `sudo apt-get install -y gawk` | `brew install gawk` |
| テスト実行 | `make test` | `make test` |

`make test` は `test-unit`・`test-dsl`・`test-e2e` を順に実行する。
e2e テストはサーバー起動 + curl による HTTP 検証であり、GitHub Actions のランナー環境でも動作する。

#### Job 3: `coverage`（ubuntu-latest のみ）

`needs: test` — matrix の全 test ジョブ（ubuntu + macos）通過後に起動する。
カバレッジ計測はコストがかかるため、ubuntu 専用とする。

**AWK カバレッジ（gawk --profile）**

```
make test-unit GAWK_OPTS=--profile=awk.prof
scripts/awk-profile-to-lcov.sh awk.prof > coverage/awk.info
```

`GAWK_OPTS` を Makefile の `test-unit` ターゲット内の gawk 呼び出しに注入することで、プロファイルデータを収集する。

**シェルスクリプトカバレッジ（kcov）**

```
kcov --include-path=bin,libexec,scripts coverage/ make test
```

`bin/hawk`・`libexec/hawk*`・テストランナースクリプトのライン実行を計測する。

**Codecov アップロード**

`codecov/codecov-action` を使用して `coverage/` 以下のデータをアップロードする。
Codecov トークンは `CODECOV_TOKEN` シークレットに格納する。

---

## AWK カバレッジ変換スクリプト

### 設計方針

`gawk --profile` が出力するプロファイルファイル（`awkprof.out`）を解析し、
LCOV 形式（`SF:` / `DA:` / `end_of_record`）に変換する。

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

実行カウントは行頭の右詰め数値フィールドとして出力される。
カウントが存在しない行は「未実行」として扱う。

### 出力フォーマット（LCOV）

```
SF:hawk.awk
DA:10,1
DA:11,3
DA:15,42
DA:16,0
end_of_record
```

### 既知の制約

gawk のプロファイル出力はソースを再フォーマットするため、元ファイルの行番号と完全には一致しない。
本スクリプトはベストエフォートでマッピングを行い、行番号のズレは許容する。
カバレッジ率の絶対値より、変化の傾向（増減）を追跡することを主目的とする。

---

## Makefile 修正

`test-unit` ターゲット内の gawk 呼び出しに `$(GAWK_OPTS)` を追加する。

```makefile
GAWK_OPTS ?=

test-unit:
    gawk -b $(GAWK_OPTS) ... -f hawk.awk ...
```

変更は1箇所のみ。`GAWK_OPTS` 未指定時の動作は現在と変わらない。

---

## 依存ツール

| ツール | 用途 | インストール方法（ubuntu） |
|--------|------|---------------------------|
| ShellCheck | シェルスクリプト静的解析 | `apt-get install shellcheck` |
| gawk | AWK 実行・lint・profile | `apt-get install gawk` |
| kcov | シェルスクリプトカバレッジ | `apt-get install kcov` |
| Codecov Action | カバレッジアップロード | `codecov/codecov-action@v4` |

---

## 成功条件

- PR に対して lint・test（ubuntu/macos 両方）・coverage の3ジョブが自動実行される
- lint または test が失敗した PR はマージブロックされる
- Codecov の PR コメントにカバレッジ率と差分が表示される
- master への push でも同じパイプラインが動作する

---

## リリースワークフローとの関係

`release-libs.yml`（タグ push → Zig クロスコンパイル → GitHub Release）は既存のまま維持する。
CI ワークフローとリリースワークフローは独立しており、相互に干渉しない。
