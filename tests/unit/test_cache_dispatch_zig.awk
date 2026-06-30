# SPDX-License-Identifier: MIT
# tests/unit/test_cache_dispatch_zig.awk

function test_cache_dispatch_zig_too_large(    saved_be, large, i, r) {
  if (system("test -d libs/cache/build -o -d libs/cache/zig-out/lib") != 0 || !LIBS_LOADED["cache"]) { TESTS_SKIPPED++; return }
  saved_be = ENVIRON["HAWK_CACHE_BACKEND"]
  ENVIRON["HAWK_CACHE_BACKEND"] = "zig"
  cache::_reset()

  large = ""
  for (i = 0; i < 600; i++) large = large "x"
  r = cache::dispatch("set", "big", large, 60)

  assert_true(!result_ok(r), "cache dispatch zig: too large ng")
  assert_eq(result_err_type(r), "CacheTooLarge", "cache dispatch zig: too large tag")

  cache::_reset()
  ENVIRON["HAWK_CACHE_BACKEND"] = saved_be
  cache::_reset()
}
