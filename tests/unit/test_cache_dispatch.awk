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

function test_cache_dispatch_file_backend_unavailable(    v) {
  cache::_reset()
  ENVIRON["HAWK_CACHE_BACKEND"] = "file"
  delete ENVIRON["HAWK_RUN_DIR"]
  v = cache::dispatch("get", "k")
  assert_true(!result_ok(v), "cache dispatch: unavailable file backend ng")
  assert_eq(result_err_type(v), "CacheUnavailable", "cache dispatch: unavailable file backend tag")
}

function test_cache_dispatch_map_error_code(    v) {
  cache::_LAST_ERROR_CODE = "LOCK_TIMEOUT"
  v = cache::_map_error_code(cache::_LAST_ERROR_CODE, "locked")
  assert_eq(result_err_type(v), "CacheLockTimeout", "cache dispatch: lock timeout tag")

  cache::_LAST_ERROR_CODE = "TOO_LARGE"
  v = cache::_map_error_code(cache::_LAST_ERROR_CODE, "big")
  assert_eq(result_err_type(v), "CacheTooLarge", "cache dispatch: too large tag")

  cache::_LAST_ERROR_CODE = "UNAVAILABLE"
  v = cache::_map_error_code(cache::_LAST_ERROR_CODE, "missing")
  assert_eq(result_err_type(v), "CacheUnavailable", "cache dispatch: unavailable tag")

  cache::_LAST_ERROR_CODE = "BACKEND"
  v = cache::_map_error_code(cache::_LAST_ERROR_CODE, "backend")
  assert_eq(result_err_type(v), "CacheBackendError", "cache dispatch: backend tag")
}

function test_cache_facade_clears_stale_error_code() {
  _test_cache_dispatch_setup()
  cache::_LAST_ERROR_CODE = "BACKEND"
  cache::get("missing")
  assert_eq(cache::_LAST_ERROR_CODE, "", "cache get clears stale error code")
  cache::_LAST_ERROR_CODE = "BACKEND"
  cache::set("k", "v", 60)
  assert_eq(cache::_LAST_ERROR_CODE, "", "cache set clears stale error code")
  cache::_LAST_ERROR_CODE = "BACKEND"
  cache::del("k")
  assert_eq(cache::_LAST_ERROR_CODE, "", "cache del clears stale error code")
  cache::_LAST_ERROR_CODE = "BACKEND"
  cache::has("k")
  assert_eq(cache::_LAST_ERROR_CODE, "", "cache has clears stale error code")
}

function test_cache_dispatch_file_set_mv_failure(    base, fakebin, old_path, mv, v) {
  cache::_reset()
  base = "/tmp/hawk-cache-dispatch-" PROCINFO["pid"]
  fakebin = base "/bin"
  system("rm -rf \"" base "\"")
  system("mkdir -p \"" fakebin "\" \"" base "/run/cache\"")
  mv = fakebin "/mv"
  print "#!/bin/sh\nexit 1" > mv
  close(mv)
  system("chmod +x \"" mv "\"")

  old_path = ENVIRON["PATH"]
  ENVIRON["PATH"] = fakebin ":" old_path
  ENVIRON["HAWK_CACHE_BACKEND"] = "file"
  ENVIRON["HAWK_RUN_DIR"] = base "/run"

  v = cache::dispatch("set", "k", "v", 60)

  ENVIRON["PATH"] = old_path
  system("rm -rf \"" base "\"")
  assert_true(!result_ok(v), "cache dispatch: file set mv failure ng")
  assert_eq(result_err_type(v), "CacheBackendError", "cache dispatch: file set mv failure tag")
}

function test_cache_dispatch_file_del_mv_failure(    base, fakebin, old_path, mv, v) {
  cache::_reset()
  base = "/tmp/hawk-cache-dispatch-del-" PROCINFO["pid"]
  fakebin = base "/bin"
  system("rm -rf \"" base "\"")
  system("mkdir -p \"" fakebin "\" \"" base "/run/cache\"")
  ENVIRON["HAWK_CACHE_BACKEND"] = "file"
  ENVIRON["HAWK_RUN_DIR"] = base "/run"
  cache::set("k", "v", 60)
  cache::_reset()

  mv = fakebin "/mv"
  print "#!/bin/sh\nexit 1" > mv
  close(mv)
  system("chmod +x \"" mv "\"")

  old_path = ENVIRON["PATH"]
  ENVIRON["PATH"] = fakebin ":" old_path
  ENVIRON["HAWK_CACHE_BACKEND"] = "file"
  ENVIRON["HAWK_RUN_DIR"] = base "/run"

  v = cache::dispatch("del", "k")

  ENVIRON["PATH"] = old_path
  system("rm -rf \"" base "\"")
  assert_true(!result_ok(v), "cache dispatch: file del mv failure ng")
  assert_eq(result_err_type(v), "CacheBackendError", "cache dispatch: file del mv failure tag")
}

function test_cache_zig_too_large_payload(    key) {
  key = sprintf("%129s", "x")
  gsub(/ /, "x", key)
  cache::_LAST_ERROR = ""
  cache::_set_zig(key, "v", 60)
  assert_true(index(cache::_LAST_ERROR, "value too large: key=129 value=1") == 1, "cache zig: too large diagnostic payload")
}
