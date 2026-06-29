# SPDX-License-Identifier: MIT
# tests/e2e/fixtures/cache_app.awk -- shared cache e2e fixture
BEGIN {
  GET("/cache/set", "cache_set")
  GET("/cache/get", "cache_get")
  GET("/worker",    "cache_worker")
}

function cache_set(    r) {
  r = cache::dispatch("set", "shared-key", "shared-value", 60)
  if (!result_ok(r)) {
    ctx::status(500)
    ctx::text("error")
    return
  }
  ctx::text("ok")
}

function cache_get(    r, v) {
  r = cache::dispatch("get", "shared-key")
  if (!result_ok(r)) {
    ctx::status(500)
    ctx::text("error")
    return
  }
  v = result_val(r)
  if (!option_some(v)) {
    ctx::status(404)
    ctx::text("miss")
    return
  }
  ctx::text(option_val(v))
}

function cache_worker() {
  ctx::text(ENVIRON["HAWK_WORKER_ID"])
}
