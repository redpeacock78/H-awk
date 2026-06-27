# SPDX-License-Identifier: MIT
# dsl/adt.awk -- Result/Option ADT runtime functions
#
# Result encoding (after Base64 fix):
#   ok   = "ok\x1F"  b64(value)
#   ng   = "ng\x1F"  TypeName              (no message)
#         | "ng\x1F" TypeName "\x1F" b64(msg)
# Option encoding:
#   some = "some\x1F" b64(value)
#   none = "none\x1F"

BEGIN {
    _adt_b64_alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    for (_adt_i = 0; _adt_i < 64; _adt_i++) {
        _adt_c = substr(_adt_b64_alpha, _adt_i + 1, 1)
        _adt_enc[_adt_i] = _adt_c
        _adt_dec[_adt_c] = _adt_i
    }
    for (_adt_i = 0; _adt_i <= 255; _adt_i++)
        _adt_ord[sprintf("%c", _adt_i)] = _adt_i
}

function _adt_b64_encode(s,    i, n, b0, b1, b2, r) {
    n = length(s); r = ""
    if (n == 0) return ""
    for (i = 1; i <= n; i += 3) {
        b0 = _adt_ord[substr(s, i,   1)]
        b1 = (i+1 <= n) ? _adt_ord[substr(s, i+1, 1)] : 0
        b2 = (i+2 <= n) ? _adt_ord[substr(s, i+2, 1)] : 0
        r = r _adt_enc[int(b0/4)]               _adt_enc[(b0%4)*16 + int(b1/16)]               _adt_enc[(b1%16)*4  + int(b2/64)]               _adt_enc[b2%64]
    }
    # Fix padding
    if (n % 3 == 1) { r = substr(r, 1, length(r)-2) "==" }
    if (n % 3 == 2) { r = substr(r, 1, length(r)-1) "="  }
    return r
}

function _adt_b64_decode(s,    i, n, c0, c1, c2, c3, r) {
    n = length(s); r = ""
    if (n == 0) return ""
    for (i = 1; i <= n; i += 4) {
        c0 = _adt_dec[substr(s, i,   1)]
        c1 = _adt_dec[substr(s, i+1, 1)]
        c2 = (substr(s, i+2, 1) == "=") ? 0 : _adt_dec[substr(s, i+2, 1)]
        c3 = (substr(s, i+3, 1) == "=") ? 0 : _adt_dec[substr(s, i+3, 1)]
        r = r sprintf("%c", c0*4 + int(c1/16))
        if (substr(s, i+2, 1) != "=") r = r sprintf("%c", (c1%16)*16 + int(c2/4))
        if (substr(s, i+3, 1) != "=") r = r sprintf("%c", (c2%4)*64  + c3)
    }
    return r
}

function result_ok(v)           { return substr(v, 1, 3) == "ok\x1F" }
function result_val(v)          { return _adt_b64_decode(substr(v, 4)) }
function result_ok_make(val)    { return "ok\x1F" _adt_b64_encode(val) }

function result_ok_from_map(values, types,    k, sep, buf, t) {
    buf = ""
    sep = ""
    for (k in values) {
        t = ((k in types)) ? types[k] : "string"
        buf = buf sep _adt_b64_encode(k) "\x1f" _adt_b64_encode(values[k]) "\x1f" t
        sep = "\x1e"
    }
    return result_ok_make(buf)
}

function result_val_into_map(res, out, out_types,    raw, n, i, recs, rest, sep1, sep2, k, v, t) {
    delete out
    delete out_types
    raw = result_val(res)
    if (raw == "") return
    n = split(raw, recs, "\x1e")
    for (i = 1; i <= n; i++) {
        if (recs[i] == "") continue
        sep1 = index(recs[i], "\x1f")
        if (sep1 == 0) continue
        k = _adt_b64_decode(substr(recs[i], 1, sep1 - 1))
        rest = substr(recs[i], sep1 + 1)
        sep2 = index(rest, "\x1f")
        if (sep2 == 0) {
            out[k] = _adt_b64_decode(rest)
            out_types[k] = "string"
            continue
        }
        v = _adt_b64_decode(substr(rest, 1, sep2 - 1))
        t = substr(rest, sep2 + 1)
        out[k] = v
        out_types[k] = t
    }
}

function result_ng(type, msg)   {
    return "ng\x1F" type (msg != "" ? "\x1F" _adt_b64_encode(msg) : "")
}
function result_err_type(v,  a) { split(substr(v, 4), a, "\x1F"); return a[1] }
function result_err(v,       a) {
    split(substr(v, 4), a, "\x1F")
    return (length(a) >= 2 && a[2] != "") ? _adt_b64_decode(a[2]) : ""
}

function option_some_make(val)  { return "some\x1F" _adt_b64_encode(val) }
function option_none_make()     { return "none\x1F" }
function option_some(v)         { return substr(v, 1, 5) == "some\x1F" }
function option_none(v)         { return v == "none\x1F" }
function option_val(v)          { return _adt_b64_decode(substr(v, 6)) }
