# SPDX-License-Identifier: MIT
# tests/unit/test_cache_dispatch.awk

function _test_cache_dispatch_setup() {
  cache::_reset()
  ENVIRON["HAWK_CACHE_BACKEND"] = "memory"
}

function test_cache_dispatch_get_miss(    v) {
  _test_cache_dispatch_setup()
  v = cache::dispatch("get", "missing-key")
  assert_true(result_ok(v), "cache dispatch: get miss ok")
  assert_true(option_none(result_val(v)), "cache dispatch: get miss none")
}

function test_cache_dispatch_get_hit(    s, v, inner) {
  _test_cache_dispatch_setup()
  s = cache::dispatch("set", "k1", "v1", 60)
  assert_true(result_ok(s), "cache dispatch: set ok")
  v = cache::dispatch("get", "k1")
  inner = result_val(v)
  assert_true(option_some(inner) && option_val(inner) == "v1", "cache dispatch: value round-trip")
}

function test_cache_dispatch_has(    s, h0, h1) {
  _test_cache_dispatch_setup()
  h0 = cache::dispatch("has", "no-such")
  assert_true(result_ok(h0) && result_val(h0) == "0", "cache dispatch: has miss ok(0)")
  s = cache::dispatch("set", "h1", "x", 60)
  h1 = cache::dispatch("has", "h1")
  assert_true(result_ok(h1) && result_val(h1) == "1", "cache dispatch: has hit ok(1)")
}

function test_cache_dispatch_del_semantics(    s, d_hit, d_miss) {
  _test_cache_dispatch_setup()
  s = cache::dispatch("set", "d1", "v", 60)
  d_hit = cache::dispatch("del", "d1")
  assert_true(result_ok(d_hit) && result_val(d_hit) == "1", "cache dispatch: del existing ok(1)")
  d_miss = cache::dispatch("del", "d1")
  assert_true(result_ok(d_miss) && result_val(d_miss) == "0", "cache dispatch: del missing ok(0)")
}

function test_cache_dispatch_unknown_method(    v) {
  _test_cache_dispatch_setup()
  v = cache::dispatch("explode")
  assert_true(!result_ok(v), "cache dispatch: unknown method ng")
  assert_eq(result_err_type(v), "CacheUnknownMethod", "cache dispatch: unknown method tag")
}
