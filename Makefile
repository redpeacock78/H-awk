# SPDX-License-Identifier: MIT
.PHONY: run dev test test-unit test-e2e lint clean help ci build-libs fetch-libs test-libs libs-clean ci-full

APP ?= app.awk

# Collect plugin files for gawk -f
PLUGIN_FILES := $(foreach d,$(wildcard plugins/*/),$(if $(wildcard $(d).disabled),,-f $(d)manifest.awk -f $(d)$(notdir $(patsubst %/,%,$(d))).awk))

help: ## 利用可能なターゲット一覧
	@awk -F':.*##' '/^[a-z0-9_-]+:.*##/ {printf "  %-12s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

run: ## サーバー起動
	./bin/hawk $(APP)

dev: ## DEV=1 でログ詳細
	DEV=1 ./bin/hawk $(APP)

test: test-unit test-e2e ## 全テスト

test-unit: ## awk 内 assert
	HAWK_NO_SERVE=1 gawk -b -f hawk.awk $(PLUGIN_FILES) -f tests/unit/run.awk

test-e2e: ## サーバー起動 + curl
	./tests/e2e/run.sh

lint: ## awk 構文チェック
	@set -e; for f in core/*.awk hawk.awk; do \
	  [ -f "$$f" ] || continue; \
	  HAWK_NO_SERVE=1 gawk --lint -f "$$f" -e 'BEGIN{exit 0}' >/dev/null 2>&1 \
	    || (echo "lint FAIL: $$f"; exit 1); \
	done
	@echo "lint OK"

ci: lint test ## lint + 全テスト (libs を除く、CI 想定)

ci-full: lint test test-libs ## lint + 全テスト + libs (Zig 必要)

clean: ## 一時ファイル削除
	rm -f data/*.tmp tests/e2e/*.log

build-libs: ## libs/* を全ビルド (Zig 必要)
	@for d in libs/*/; do \
	  [ "$$d" = "libs/_common/" ] && continue; \
	  [ -f "$${d}build.zig" ] || continue; \
	  echo "Building $$d"; \
	  (cd "$$d" && zig build -Doptimize=ReleaseSafe); \
	done

fetch-libs: ## GitHub Release から precompiled 取得 (Zig 不要)
	./scripts/fetch-libs.sh

test-libs: ## libs/*/zig build test (Zig 必要)
	@for d in libs/*/; do \
	  [ "$$d" = "libs/_common/" ] && continue; \
	  [ -f "$${d}build.zig" ] || continue; \
	  echo "Testing $$d"; \
	  (cd "$$d" && zig build test); \
	done

libs-clean: ## libs ビルド成果削除
	@for d in libs/*/; do rm -rf "$${d}zig-out" "$${d}zig-cache" "$${d}.zig-cache"; done
