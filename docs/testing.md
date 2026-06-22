🌐 [日本語](ja/testing.ja.md) | [← Back to README](../README.md)

# Testing

```sh
make test           # unit + dsl + e2e
make test-unit      # AWK assertions only (fast, no server)
make test-dsl       # DSL desugar fixture tests
make test-e2e       # server + curl integration tests
make test-libs      # Zig lib unit tests
make lint           # gawk --lint syntax check
make ci             # lint + all tests
```
