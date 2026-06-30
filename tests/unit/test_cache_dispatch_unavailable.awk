# SPDX-License-Identifier: MIT
# tests/unit/test_cache_dispatch_unavailable.awk

function test_cache_dispatch_off_backend(    saved_be, s, g) {
  saved_be = ENVIRON["HAWK_CACHE_BACKEND"]
  ENVIRON["HAWK_CACHE_BACKEND"] = "off"
  cache::_reset()

  g = cache::dispatch("get", "missing")
  s = cache::dispatch("set", "k", "v", 60)

  assert_true(result_ok(g), "cache dispatch off: get ok")
  assert_true(option_none(result_val(g)), "cache dispatch off: get none")
  assert_true(result_ok(s), "cache dispatch off: set ok")
  assert_eq(result_val(s), "", "cache dispatch off: set returns empty")
  assert_true(result_err_type(g) != "CacheUnavailable", "cache dispatch off: get is not unavailable")
  assert_true(result_err_type(s) != "CacheUnavailable", "cache dispatch off: set is not unavailable")

  cache::_reset()
  ENVIRON["HAWK_CACHE_BACKEND"] = saved_be
  cache::_reset()
}
