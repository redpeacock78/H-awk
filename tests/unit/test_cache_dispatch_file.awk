# SPDX-License-Identifier: MIT
# tests/unit/test_cache_dispatch_file.awk

function test_cache_dispatch_file_round_trip(    saved_be, saved_dir, dir, s, g, opt) {
  saved_be  = ENVIRON["HAWK_CACHE_BACKEND"]
  saved_dir = ENVIRON["HAWK_RUN_DIR"]
  dir = "/tmp/hawk_cache_dispatch_file_" PROCINFO["pid"]
  system("rm -rf \"" dir "\" && mkdir -p \"" dir "/cache\"")
  ENVIRON["HAWK_CACHE_BACKEND"] = "file"
  ENVIRON["HAWK_RUN_DIR"] = dir
  cache::_reset()

  s = cache::dispatch("set", "file-k", "file-v", 60)
  g = cache::dispatch("get", "file-k")
  opt = result_val(g)

  assert_true(result_ok(s), "cache dispatch file: set ok")
  assert_eq(result_val(s), "", "cache dispatch file: set returns empty")
  assert_true(result_ok(g), "cache dispatch file: get ok")
  assert_true(option_some(opt) && option_val(opt) == "file-v", "cache dispatch file: get some value")

  cache::_reset()
  system("rm -rf \"" dir "\"")
  ENVIRON["HAWK_CACHE_BACKEND"] = saved_be
  ENVIRON["HAWK_RUN_DIR"] = saved_dir
  cache::_reset()
}

function test_cache_dispatch_file_lock_timeout(    saved_be, saved_dir, dir, lockdir, pidfile, pid, r) {
  saved_be  = ENVIRON["HAWK_CACHE_BACKEND"]
  saved_dir = ENVIRON["HAWK_RUN_DIR"]
  dir = "/tmp/hawk_cache_dispatch_file_lock_" PROCINFO["pid"]
  lockdir = dir "/cache/cache.lock.d"
  pidfile = dir "/sleep.pid"
  system("rm -rf \"" dir "\" && mkdir -p \"" lockdir "\"")
  system("sh -c 'sleep 30 & echo $! > \"" pidfile "\"'")
  getline pid < pidfile
  close(pidfile)
  print pid > (lockdir "/owner_pid")
  close(lockdir "/owner_pid")
  ENVIRON["HAWK_CACHE_BACKEND"] = "file"
  ENVIRON["HAWK_RUN_DIR"] = dir
  cache::_reset()

  r = cache::dispatch("set", "locked", "v", 60)

  system("kill " pid " 2>/dev/null")
  assert_true(!result_ok(r), "cache dispatch file: lock timeout ng")
  assert_eq(result_err_type(r), "CacheLockTimeout", "cache dispatch file: lock timeout tag")

  cache::_reset()
  system("rm -rf \"" dir "\"")
  ENVIRON["HAWK_CACHE_BACKEND"] = saved_be
  ENVIRON["HAWK_RUN_DIR"] = saved_dir
  cache::_reset()
}
