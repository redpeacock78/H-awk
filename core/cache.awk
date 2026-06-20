# SPDX-License-Identifier: MIT
# core/cache.awk — cache facade (memory / file / zig backend)
@namespace "cache"

BEGIN {
  _BACKEND    = ""
  _FOUND      = 0
  _LAST_ERROR = ""
  _STATS_HIT  = 0
  _STATS_MISS = 0
  _STATS_SET  = 0
}

function get(key,    b) {
  _FOUND = 0
  b = _detect_backend()
  if (b == "off")    return ""
  if (b == "memory") return _get_memory(key)
  if (b == "file")   return _get_file(key)
  if (b == "zig")    return _get_zig(key)
  _STATS_MISS++
  return ""
}

function set(key, value, ttl_sec,    b) {
  b = _detect_backend()
  if (b == "off")    return
  if (b == "memory") { _set_memory(key, value, ttl_sec); return }
  if (b == "file")   { _set_file(key, value, ttl_sec);   return }
  if (b == "zig")    { _set_zig(key, value, ttl_sec);    return }
}

function del(key,    b) {
  b = _detect_backend()
  if (b == "off")    return
  if (b == "memory") { _del_memory(key); return }
  if (b == "file")   { _del_file(key);   return }
  if (b == "zig")    { _del_zig(key);    return }
}

function has(key) { get(key); return _FOUND }

function found()      { return _FOUND }
function last_error() { return _LAST_ERROR }

function backend() { return _detect_backend() }

function remember(key, ttl_sec, fn,    v) {
  v = get(key)
  if (_FOUND) return v
  v = @fn()
  set(key, v, ttl_sec)
  return v
}

function stats() {
  return "backend=" _BACKEND " hit=" _STATS_HIT " miss=" _STATS_MISS " set=" _STATS_SET
}

function _detect_backend(    b, rd, test_f, rc) {
  if (_BACKEND != "") return _BACKEND
  b = ENVIRON["HAWK_CACHE_BACKEND"]
  if (b == "") b = "auto"

  if (b == "off")    { _BACKEND = "off";    return _BACKEND }
  if (b == "memory") { _BACKEND = "memory"; return _BACKEND }

  if (b == "zig") {
    if (LIBS_LOADED["cache"]) { _BACKEND = "zig"; return _BACKEND }
    print "[hawk] cache: HAWK_CACHE_BACKEND=zig but libhawk_cache not loaded" > "/dev/stderr"
    exit 1
  }

  if (b == "file") {
    rd = ENVIRON["HAWK_RUN_DIR"]
    if (rd == "") {
      print "[hawk] cache: HAWK_CACHE_BACKEND=file requires HAWK_RUN_DIR" > "/dev/stderr"
      exit 1
    }
    _BACKEND = "file"; return _BACKEND
  }

  if (b == "auto") {
    if (LIBS_LOADED["cache"]) { _BACKEND = "zig"; return _BACKEND }
    rd = ENVIRON["HAWK_RUN_DIR"]
    if (rd != "") {
      test_f = rd "/cache/.hawk_write_test_" PROCINFO["pid"]
      rc = system("mkdir -p \"" rd "/cache\" && touch \"" test_f "\" 2>/dev/null && rm -f \"" test_f "\"")
      if (rc == 0) { _BACKEND = "file"; return _BACKEND }
    }
    _BACKEND = "memory"; return _BACKEND
  }

  _BACKEND = "memory"; return _BACKEND
}

function _get_memory(key,    now, expires) {
  if (!(key in _mem_value)) { _STATS_MISS++; return "" }
  now     = awk::systime()
  expires = _mem_expires[key]
  if (expires > 0 && now >= expires) {
    delete _mem_value[key]
    delete _mem_expires[key]
    _STATS_MISS++
    return ""
  }
  _FOUND = 1
  _STATS_HIT++
  return _mem_value[key]
}

function _set_memory(key, value, ttl_sec) {
  _mem_value[key]   = value
  _mem_expires[key] = (ttl_sec > 0) ? awk::systime() + ttl_sec : 0
  _STATS_SET++
}

function _del_memory(key) {
  delete _mem_value[key]
  delete _mem_expires[key]
}

# stubs — Task 2 で実装
function _get_file(key)                 { _STATS_MISS++; return "" }
function _set_file(key, value, ttl_sec) { }
function _del_file(key)                 { }

# stubs — Task 7 で実装
function _get_zig(key)                  { _STATS_MISS++; return "" }
function _set_zig(key, value, ttl_sec)  { }
function _del_zig(key)                  { }

function _reset(    k) {
  _BACKEND    = ""
  _FOUND      = 0
  _LAST_ERROR = ""
  _STATS_HIT  = 0
  _STATS_MISS = 0
  _STATS_SET  = 0
  for (k in _mem_value)   delete _mem_value[k]
  for (k in _mem_expires) delete _mem_expires[k]
}

@namespace "awk"
