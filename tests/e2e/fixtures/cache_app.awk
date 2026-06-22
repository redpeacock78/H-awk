# SPDX-License-Identifier: MIT
# tests/e2e/fixtures/cache_app.awk -- shared cache e2e fixture
BEGIN {
  GET("/cache/set", "cache_set")
  GET("/cache/get", "cache_get")
  GET("/worker",    "cache_worker")
}

function cache_set() {
  cache::set("shared-key", "shared-value", 60)
  ctx::text("ok")
}

function cache_get(    v) {
  v = cache::get("shared-key")
  if (!cache::found()) {
    ctx::status(404)
    ctx::text("miss")
    return
  }
  ctx::text(v)
}

function cache_worker() {
  ctx::text(ENVIRON["HAWK_WORKER_ID"])
}
