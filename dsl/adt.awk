# SPDX-License-Identifier: MIT
# dsl/adt.awk -- Result/Option ADT runtime functions
#
# Result encoding:
#   ok  = "ok\x1F" value
#   ng  = "ng\x1F" TypeName  or  "ng\x1F" TypeName "\x1F" msg
# Option encoding: unchanged (non-empty = some, "" = none)

function result_ok(v)          { return substr(v, 1, 3) == "ok\x1F" }
function result_val(v)         { return substr(v, 4) }
function result_ok_make(val)   { return "ok\x1F" val }
function result_ng(type, msg)  {
  return "ng\x1F" type (msg != "" ? "\x1F" msg : "")
}
function result_err_type(v,  a) { split(substr(v, 4), a, "\x1F"); return a[1] }
function result_err(v)         { return substr(v, 4) }

function option_some(v) { return v != "" }
function option_val(v)  { return v }
