# SPDX-License-Identifier: MIT
# core/cache.awk — cache facade (memory / file / zig backend)
@namespace "cache"

BEGIN {
  _BACKEND    = ""
  _FOUND      = 0
  _LAST_ERROR = ""
  _LAST_ERROR_CODE = ""

  _CACHE_ROUTES["get"]      = "cache::get";      _CACHE_ARITY["get"]      = 1
  _CACHE_ROUTES["set"]      = "cache::set";      _CACHE_ARITY["set"]      = 3
  _CACHE_ROUTES["del"]      = "cache::del";      _CACHE_ARITY["del"]      = 1
  _CACHE_ROUTES["has"]      = "cache::has";      _CACHE_ARITY["has"]      = 1
}

function dispatch(path, a1, a2, a3,    v, existed) {
  _LAST_ERROR_CODE = ""
  if (path == "get") {
    v = get(a1)
    if (_LAST_ERROR_CODE != "") return _map_error_code(_LAST_ERROR_CODE, _LAST_ERROR)
    if (_FOUND) return awk::result_ok_make(awk::option_some_make(v))
    return awk::result_ok_make(awk::option_none_make())
  }
  if (path == "set") {
    set(a1, a2, a3)
    if (_LAST_ERROR_CODE != "") return _map_error_code(_LAST_ERROR_CODE, _LAST_ERROR)
    return awk::result_ok_make("")
  }
  if (path == "has") {
    v = has(a1) ? "1" : "0"
    if (_LAST_ERROR_CODE != "") return _map_error_code(_LAST_ERROR_CODE, _LAST_ERROR)
    return awk::result_ok_make(v)
  }
  if (path == "del") {
    existed = has(a1) ? "1" : "0"
    if (_LAST_ERROR_CODE != "") return _map_error_code(_LAST_ERROR_CODE, _LAST_ERROR)
    del(a1)
    if (_LAST_ERROR_CODE != "") return _map_error_code(_LAST_ERROR_CODE, _LAST_ERROR)
    return awk::result_ok_make(existed)
  }
  return awk::result_ng("CacheUnknownMethod", path)
}

function _map_error_code(code, msg) {
  if (code == "LOCK_TIMEOUT") return awk::result_ng("CacheLockTimeout", msg)
  if (code == "TOO_LARGE")    return awk::result_ng("CacheTooLarge",    msg)
  if (code == "UNAVAILABLE")  return awk::result_ng("CacheUnavailable", msg)
  return awk::result_ng("CacheBackendError", msg)
}

function get(key,    b) {
  _LAST_ERROR_CODE = ""
  _FOUND = 0
  b = _detect_backend()
  if (b == "off")    return ""
  if (b == "unavailable") return ""
  if (b == "zig")    return _get_zig(key)
  if (b == "file")   return _get_file(key)
  if (b == "memory") return _get_memory(key)
  return ""
}

function set(key, value, ttl_sec,    b) {
  _LAST_ERROR_CODE = ""
  b = _detect_backend()
  if (b == "off")    return
  if (b == "unavailable") return
  if (b == "zig")    { _set_zig(key, value, ttl_sec); return }
  if (b == "file")   { _set_file(key, value, ttl_sec); return }
  if (b == "memory") { _set_memory(key, value, ttl_sec); return }
}

function del(key,    b) {
  _LAST_ERROR_CODE = ""
  b = _detect_backend()
  if (b == "off")    return
  if (b == "unavailable") return
  if (b == "zig")    { _del_zig(key); return }
  if (b == "file")   { _del_file(key); return }
  if (b == "memory") { _del_memory(key); return }
}

function has(key,    b) {
  _LAST_ERROR_CODE = ""
  b = _detect_backend()
  if (b == "unavailable") return 0
  get(key)
  return _FOUND
}

function last_error() { return _LAST_ERROR }

function _detect_backend(    b, rd, test_f, rc) {
  if (_BACKEND != "") {
    if (_BACKEND == "unavailable") _LAST_ERROR_CODE = "UNAVAILABLE"
    return _BACKEND
  }
  b = ENVIRON["HAWK_CACHE_BACKEND"]
  if (b == "") b = "auto"

  if (b == "off")    { _BACKEND = "off";    return _BACKEND }
  if (b == "memory") { _BACKEND = "memory"; return _BACKEND }

  if (b == "zig") {
    if (awk::LIBS_LOADED["cache"]) { _BACKEND = "zig"; return _BACKEND }
    _LAST_ERROR = "HAWK_CACHE_BACKEND=zig but libhawk_cache not loaded"
    _LAST_ERROR_CODE = "UNAVAILABLE"
    print "[hawk] cache: HAWK_CACHE_BACKEND=zig but libhawk_cache not loaded" > "/dev/stderr"
    _BACKEND = "unavailable"; return _BACKEND
  }

  if (b == "file") {
    rd = ENVIRON["HAWK_RUN_DIR"]
    if (rd == "") {
      _LAST_ERROR = "HAWK_RUN_DIR not set"
      _LAST_ERROR_CODE = "UNAVAILABLE"
      print "[hawk] cache: HAWK_CACHE_BACKEND=file requires HAWK_RUN_DIR" > "/dev/stderr"
      _BACKEND = "unavailable"; return _BACKEND
    }
    _BACKEND = "file"; return _BACKEND
  }

  if (b == "auto") {
    if (awk::LIBS_LOADED["cache"] && (!("HAWK_RUN_DIR" in ENVIRON) || ENVIRON["HAWK_RUN_DIR"] != "")) { _BACKEND = "zig"; return _BACKEND }
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
  _LAST_ERROR_CODE = ""
  if (!(key in _mem_value)) { return "" }
  now     = awk::systime()
  expires = _mem_expires[key]
  if (expires > 0 && now >= expires) {
    delete _mem_value[key]
    delete _mem_expires[key]
    return ""
  }
  _FOUND = 1
  return _mem_value[key]
}

function _set_memory(key, value, ttl_sec) {
  _LAST_ERROR_CODE = ""
  _mem_value[key]   = value
  _mem_expires[key] = (ttl_sec > 0) ? awk::systime() + ttl_sec : 0
}

function _del_memory(key) {
  _LAST_ERROR_CODE = ""
  delete _mem_value[key]
  delete _mem_expires[key]
}

function _get_zig(key,    v) {
  _LAST_ERROR_CODE = ""
  v = awk::hawk_cache_get(key)
  if (awk::hawk_cache_found() != 1) {
    return ""
  }
  _FOUND = 1
  return v
}
function _set_zig(key, value, ttl_sec) {
  _LAST_ERROR_CODE = ""
  if (length(key) > 128 || length(value) > 512) {
    _LAST_ERROR = "value too large: key=" length(key) " value=" length(value)
    _LAST_ERROR_CODE = "TOO_LARGE"
    return
  }
  awk::hawk_cache_set(key, value, ttl_sec * 1000)
}
function _del_zig(key) {
  _LAST_ERROR_CODE = ""
  awk::hawk_cache_del(key)
}

# escape / unescape for file backend
function _escape(v,    s) {
  s = v
  gsub(/\\/, "\\\\", s)
  gsub(/\t/, "\\t",  s)
  gsub(/\n/, "\\n",  s)
  gsub(/\r/, "\\r",  s)
  return s
}

function _unescape(v,    out, i, n, c, nc) {
  out = ""; n = length(v)
  for (i = 1; i <= n; i++) {
    c = substr(v, i, 1)
    if (c == "\\" && i < n) {
      nc = substr(v, i + 1, 1); i++
      if      (nc == "\\") out = out "\\"
      else if (nc == "t")  out = out "\t"
      else if (nc == "n")  out = out "\n"
      else if (nc == "r")  out = out "\r"
      else                 out = out nc
    } else {
      out = out c
    }
  }
  return out
}

# djb2-like hash for file backend (collision-safe: full key compare follows)
function _key_hash(key,    h, i) {
  h = 5381
  for (i = 1; i <= length(key); i++)
    h = (h * 33 + (index(" !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~", substr(key, i, 1)) + 32)) % 1000003
  return sprintf("%d", h)
}

function _file_path(    rd) {
  rd = ENVIRON["HAWK_RUN_DIR"]
  return rd "/cache/cache.tsv"
}

function _lock_path(    rd) {
  rd = ENVIRON["HAWK_RUN_DIR"]
  return rd "/cache/cache.lock.d"
}

function _lock_acquire(lockdir,    owner_file, pid, i) {
  owner_file = lockdir "/owner_pid"
  for (i = 0; i < 20; i++) {
    if (system("mkdir \"" lockdir "\" 2>/dev/null") == 0) {
      print PROCINFO["pid"] > owner_file
      close(owner_file)
      return 1
    }
    if ((getline pid < owner_file) > 0) {
      close(owner_file)
      if (system("kill -0 " pid " 2>/dev/null") != 0) {
        system("rm -rf \"" lockdir "\"")
        continue
      }
    } else { close(owner_file) }
    system("sleep 0.05")
  }
  return 0
}

function _lock_release(lockdir) {
  system("rm -rf \"" lockdir "\"")
}

function _get_file(key,    fpath, line, parts, n, kh, now, xp) {
  _LAST_ERROR_CODE = ""
  _FOUND = 0
  fpath = _file_path()
  kh    = _key_hash(key)
  now   = awk::systime()
  while ((getline line < fpath) > 0) {
    n = split(line, parts, "\t")
    if (n < 4) continue
    if (parts[1] != kh) continue
    if (_unescape(parts[3]) != key) continue
    xp = parts[2] + 0
    if (xp > 0 && now >= xp) continue
    close(fpath)
    _FOUND = 1
    return _unescape(parts[4])
  }
  close(fpath)
  return ""
}

function _set_file(key, value, ttl_sec,    fpath, lockdir, tmp, kh, ek, ev, xp, now, line, parts, n, out, rc) {
  _LAST_ERROR_CODE = ""
  fpath   = _file_path()
  lockdir = _lock_path()
  tmp     = fpath "." PROCINFO["pid"] ".tmp"
  kh      = _key_hash(key)
  ek      = _escape(key)
  ev      = _escape(value)
  xp      = (ttl_sec > 0) ? awk::systime() + ttl_sec : 0
  now     = awk::systime()

  if (!_lock_acquire(lockdir)) { _LAST_ERROR = "CacheLockTimeout"; _LAST_ERROR_CODE = "LOCK_TIMEOUT"; return }

  out = ""
  while ((getline line < fpath) > 0) {
    n = split(line, parts, "\t")
    if (n < 4) continue
    if (parts[1] == kh && _unescape(parts[3]) == key) continue
    if ((parts[2] + 0) > 0 && now >= (parts[2] + 0)) continue
    out = out line "\n"
  }
  close(fpath)
  out = out kh "\t" xp "\t" ek "\t" ev "\n"
  printf "%s", out > tmp; close(tmp)
  rc = system("mv \"" tmp "\" \"" fpath "\"")
  if (rc != 0) {
    _LAST_ERROR = "mv failed: " tmp " -> " fpath
    _LAST_ERROR_CODE = "BACKEND"
    _lock_release(lockdir)
    system("rm -f \"" tmp "\"")
    return
  }
  _lock_release(lockdir)
}

function _del_file(key,    fpath, lockdir, tmp, kh, now, line, parts, n, out, rc) {
  _LAST_ERROR_CODE = ""
  fpath   = _file_path()
  lockdir = _lock_path()
  tmp     = fpath "." PROCINFO["pid"] ".tmp"
  kh      = _key_hash(key)
  now     = awk::systime()

  if (!_lock_acquire(lockdir)) { _LAST_ERROR = "CacheLockTimeout"; _LAST_ERROR_CODE = "LOCK_TIMEOUT"; return }

  out = ""
  while ((getline line < fpath) > 0) {
    n = split(line, parts, "\t")
    if (n < 4) continue
    if (parts[1] == kh && _unescape(parts[3]) == key) continue
    if ((parts[2] + 0) > 0 && now >= (parts[2] + 0)) continue
    out = out line "\n"
  }
  close(fpath)
  printf "%s", out > tmp; close(tmp)
  rc = system("mv \"" tmp "\" \"" fpath "\"")
  if (rc != 0) {
    _LAST_ERROR = "mv failed: " tmp " -> " fpath
    _LAST_ERROR_CODE = "BACKEND"
    _lock_release(lockdir)
    system("rm -f \"" tmp "\"")
    return
  }
  _lock_release(lockdir)
}

function _reset(    k) {
  _BACKEND    = ""
  _FOUND      = 0
  _LAST_ERROR = ""
  _LAST_ERROR_CODE = ""
  for (k in _mem_value)   delete _mem_value[k]
  for (k in _mem_expires) delete _mem_expires[k]
}

@namespace "awk"
