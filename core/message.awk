# SPDX-License-Identifier: MIT
# core/message.awk -- message envelope
@namespace "message"

BEGIN {
  _RS = sprintf("%c", 30)
  _US = sprintf("%c", 31)
  _seq = 0
}

function ref(    ts, s) {
  ts = awk::systime()
  _seq++
  return ts "_" PROCINFO["pid"] "_" _seq
}

function make_call(to, frm, selector, args_str, reply_to, timeout_ms,    r) {
  r = ref()
  return to _RS frm _RS r _RS "call" _RS selector _RS args_str _RS reply_to _RS timeout_ms _RS ""
}

function make_cast(to, frm, selector, args_str,    r) {
  r = ref()
  return to _RS frm _RS r _RS "cast" _RS selector _RS args_str _RS "" _RS "" _RS ""
}

function make_reply(to, frm, ref_val, payload) {
  return to _RS frm _RS ref_val _RS "reply" _RS "" _RS payload _RS "" _RS "" _RS ""
}

function make_error(to, frm, ref_val, err_type, err_msg) {
  return to _RS frm _RS ref_val _RS "error" _RS err_type _RS err_msg _RS "" _RS "" _RS ""
}

function decode(line, out,    parts, n) {
  n = split(line, parts, _RS)
  if (n < 4) return 0
  out["to"]         = parts[1]
  out["from"]       = parts[2]
  out["ref"]        = parts[3]
  out["kind"]       = parts[4]
  out["selector"]   = (n >= 5) ? parts[5] : ""
  out["args"]       = (n >= 6) ? parts[6] : ""
  out["reply_to"]   = (n >= 7) ? parts[7] : ""
  out["timeout_ms"] = (n >= 8) ? parts[8] : ""
  out["trace_id"]   = (n >= 9) ? parts[9] : ""
  return 1
}

@namespace "awk"
