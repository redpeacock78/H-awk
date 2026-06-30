#!/usr/bin/env bash
set -euo pipefail

# caller-only lint (default)。core/cache.awk (旧 API 定義 + _CACHE_ROUTES +
# dispatch パススルー枝) と dsl/sig.awk (旧 sig は Task 6 まで温存) は除外する。
# Task 6 で旧 API 定義を削除した後は --strict で除外なしモードに切替え、
# 削除漏れを機械検出する。
strict=0
if [ "${1:-}" = "--strict" ]; then
    strict=1
fi

find_args=(. -name "*.awk" ! -path "./docs/superpowers/*")
if [ "$strict" -eq 0 ]; then
    find_args+=(! -path "./core/cache.awk" ! -path "./dsl/sig.awk")
fi

violations=$(
    while IFS= read -r -d '' file; do
        grep -n \
            -e 'cache\.\(remember\|stats\|backend\|found\)' \
            -e 'cache::\(remember\|stats\|backend\|found\)' \
            "$file" | sed "s|^|$file:|" || true
    done < <(find "${find_args[@]}" -print0)
)

if [ -n "$violations" ]; then
    echo "ERROR: legacy cache API references found:" >&2
    echo "$violations" >&2
    exit 1
fi

if [ "$strict" -eq 1 ]; then
    echo "OK: no legacy cache API references anywhere (strict)."
else
    echo "OK: no legacy cache API callers."
fi
