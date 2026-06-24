🌐 [English](../testing.md) | [← README に戻る](../../README.ja.md)

# テスト

```sh
make test           # unit + dsl + e2e
make test-unit      # AWK アサーションのみ (高速、サーバー不要)
make test-dsl       # DSL デシュガー フィクスチャテスト
make test-e2e       # サーバー + curl 統合テスト
make test-libs      # Zig ライブラリユニットテスト
make lint           # gawk --lint 構文チェック
make ci             # lint + 全テスト
```

テストには DSL コレクション型チェック（`List`/`Dict`/`Record` の型違反検出）、`libs/url` ユニットテスト（encode/decode/query）、`libs/json` ユニットテスト（encode/decode/parse error）、`libs/gzip` ユニットテスト（gzip negotiation/headers/fallback）が含まれます。
