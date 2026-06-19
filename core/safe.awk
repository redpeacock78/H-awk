# SPDX-License-Identifier: MIT
# core/safe.awk -- safe:: namespace: HTML sanitizers and trusted escape hatches

@namespace "safe"

BEGIN {
    _SAFE_ROUTES["html.escape"]   = "safe::html_escape"
    _SAFE_ROUTES["html.raw"]      = "safe::html_raw"
    _SAFE_ROUTES["html.fragment"] = "safe::html_fragment"
    _SAFE_ROUTES["attr.escape"]   = "safe::attr_escape"
    _SAFE_ROUTES["str.trust"]     = "safe::str_trust"
    _SAFE_ARITY["html.escape"]    = 1
    _SAFE_ARITY["html.raw"]       = 1
    _SAFE_ARITY["html.fragment"]  = 3
    _SAFE_ARITY["attr.escape"]    = 1
    _SAFE_ARITY["str.trust"]      = 1
}

function html_escape(s) {
    gsub(/&/, "\\&amp;", s)
    gsub(/</, "\\&lt;", s)
    gsub(/>/, "\\&gt;", s)
    gsub(/"/, "\\&quot;", s)
    gsub(/'/, "\\&#39;", s)
    return s
}

function attr_escape(s) {
    gsub(/&/, "\\&amp;", s)
    gsub(/</, "\\&lt;", s)
    gsub(/>/, "\\&gt;", s)
    gsub(/"/, "\\&quot;", s)
    gsub(/'/, "\\&#39;", s)
    return s
}

function html_raw(s) {
    return s
}

function str_trust(s) {
    return s ""
}

function html_fragment(a, b, c) {
    return a b c
}

function fragment_v(arr, n,    i, out) {
    out = ""
    for (i = 1; i <= n; i++) out = out arr[i]
    return out
}

function dispatch(path, a1, a2, a3) {
    return hawk_dispatch::call("safe", _SAFE_ROUTES, _SAFE_ARITY, path, a1, a2, a3)
}

@namespace "awk"
