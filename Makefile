.PHONY: run dev test test-unit test-e2e lint clean help ci

APP ?= app.awk

# Collect plugin files for gawk -f
PLUGIN_FILES := $(foreach d,$(wildcard plugins/*/),$(if $(wildcard $(d).disabled),,-f $(d)manifest.awk -f $(d)$(notdir $(patsubst %/,%,$(d))).awk))

help: ## 利用可能なターゲット一覧
	@awk -F':.*##' '/^[a-z_-]+:.*##/ {printf "  %-12s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

run: ## サーバー起動
	./bin/hawk $(APP)

dev: ## DEV=1 でログ詳細
	DEV=1 ./bin/hawk $(APP)

test: test-unit test-e2e ## 全テスト

test-unit: ## awk 内 assert
	HAWK_NO_SERVE=1 gawk -f hawk.awk $(PLUGIN_FILES) -f tests/unit/run.awk

test-e2e: ## サーバー起動 + curl
	./tests/e2e/run.sh

lint: ## awk 構文チェック
	@set -e; for f in core/*.awk hawk.awk; do \
	  [ -f "$$f" ] || continue; \
	  gawk --lint -f "$$f" -e 'BEGIN{exit 0}' >/dev/null 2>&1 \
	    || (echo "lint FAIL: $$f"; exit 1); \
	done
	@echo "lint OK"

ci: lint test ## lint + 全テスト (CI 想定)

clean: ## 一時ファイル削除
	rm -f data/*.tmp tests/e2e/*.log
