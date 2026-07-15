# SPDX-License-Identifier: MIT
.PHONY: run dev bench check emit test test-unit test-dsl test-dsl2 test-cli test-desugar test-e2e lint clean help ci build-libs fetch-libs test-libs libs-clean ci-full

APP     ?= app.awk
WORKERS ?= 4
PORT    ?= 8080
STRICT  ?=
GAWK_OPTS ?=

# Collect plugin files for gawk -f
PLUGIN_FILES := $(foreach d,$(wildcard plugins/*/),$(if $(wildcard $(d).disabled),,-f $(d)manifest.awk -f $(d)$(notdir $(patsubst %/,%,$(d))).awk))

help: ## 利用可能なターゲット一覧
	@awk -F':.*##' '/^[a-z0-9_-]+:.*##/ {printf "  %-12s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

run: ## サーバー起動 (WORKERS=N, STRICT=1)
	./bin/hawk serve --workers $(WORKERS) $(APP)

bench: ## cache on/off benchmark (hey が必要)
	@echo "=== cache on (zig backend, 8 workers) ===" && \
	HAWK_CACHE_BACKEND=zig ./bin/hawk serve --workers 8 $(APP) & BENCH_PID=$$!; \
	sleep 2; \
	hey -n 10000 -c 100 http://127.0.0.1:$(PORT)/todos.json; \
	kill $$BENCH_PID 2>/dev/null || true
	@echo ""
	@echo "=== cache off (8 workers) ===" && \
	HAWK_CACHE_BACKEND=off ./bin/hawk serve --workers 8 $(APP) & BENCH_PID=$$!; \
	sleep 2; \
	hey -n 10000 -c 100 http://127.0.0.1:$(PORT)/todos.json; \
	kill $$BENCH_PID 2>/dev/null || true

dev: ## DEV=1 でログ詳細
	DEV=1 ./bin/hawk serve --workers $(WORKERS) $(APP)

check: ## DSL 型検査のみ (サーバー起動なし)
	./bin/hawk check $(if $(STRICT),--strict) $(APP)

emit: ## desugar 済み AWK を stdout 出力
	./bin/hawk emit $(if $(STRICT),--strict) $(APP)

test: test-unit test-dsl test-dsl2 test-cli test-desugar test-e2e ## 全テスト

test-unit: ## awk 内 assert
	@libs_args=""; libs_vars=""; \
	so_ext="$(if $(filter Darwin,$(shell uname -s)),dylib,so)"; \
	for d in libs/*/; do \
	  [ "$$d" = "libs/_common/" ] && continue; \
	  name=$$(basename "$$d"); \
	  so="$$d/zig-out/lib/libhawk_$$name.$$so_ext"; \
	  [ -f "$$so" ] || continue; \
	  libs_args="$$libs_args -l $$so"; \
	  libs_vars="$$libs_vars -v HAWK_LIBS_$$name=1"; \
	done; \
	_u_log=$$(mktemp); \
	LC_ALL=C HAWK_NO_SERVE=1 gawk -b $(GAWK_OPTS) $$libs_args $$libs_vars -f hawk.awk $(PLUGIN_FILES) -f tests/unit/run.awk 2>"$$_u_log"; \
	_u_ret=$$?; \
	grep -v "multipart/form-data received but libs/multipart not loaded" "$$_u_log" >&2; \
	rm -f "$$_u_log"; \
	exit $$_u_ret

test-dsl: ## DSL desugar 単体テスト
	./tests/unit/dsl/run.sh

test-dsl2: ## DSL v2 工程別 golden テスト
	./tests/dsl2/run.sh

test-cli: ## CLI 単体テスト
	./tests/unit/cli/run.sh

test-desugar: ## multi-file desugar テスト
	./tests/unit/desugar/run.sh

test-e2e: ## サーバー起動 + curl
	./tests/e2e/run.sh

lint: ## awk 構文チェック
	@HAWK_NO_SERVE=1 gawk --lint -f hawk.awk -e 'BEGIN{exit 0}' >/dev/null 2>&1 \
	  || (echo "lint FAIL"; exit 1)
	@echo "lint OK"
	@./tests/lint/no_legacy_cache_callers.sh

ci: lint test ## lint + 全テスト (libs を除く、CI 想定)

ci-full: lint test test-libs ## lint + 全テスト + libs (Zig 必要)

clean: ## 一時ファイル削除
	rm -f data/*.tmp tests/e2e/*.log

build-libs: ## libs/* を全ビルド (Zig 必要)
	@for d in libs/*/; do \
	  [ "$$d" = "libs/_common/" ] && continue; \
	  [ -f "$${d}build.zig" ] || continue; \
	  echo "Building $$d"; \
	  (cd "$$d" && zig build); \
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
	@(cd libs/net && zig build)
	@bash libs/net/tests/split_recv_test.sh

libs-clean: ## libs ビルド成果削除
	@for d in libs/*/; do rm -rf "$${d}zig-out" "$${d}zig-cache" "$${d}.zig-cache"; done
