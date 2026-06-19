# SPDX-License-Identifier: MIT
# core/ctx.awk -- Hono-style Context API
#
# ctx::req[], ctx::res[] are populated by _ctx_load() before each handler call.
# _ctx_save() copies ctx::res[] back to res[] after the handler returns.
# All route handlers use ctx:: directly; router calls @handler() with 0 args
# so all declared params are true local variables.
#
# Requires gawk 5.0+ (@namespace support).

@namespace "ctx"

# --- Request helpers ---

function query(key,       k) { k = "query:" key; if (!(k in ctx::req)) return awk::result_ng("ParseError", "missing " key); return awk::result_ok_make(ctx::req[k]) }
function param(key,       k) { k = "params:" key; if (!(k in ctx::req)) return awk::result_ng("ParseError", "missing " key); return awk::result_ok_make(ctx::req[k]) }
function get_header(key,  k) { k = "header:" awk::to_lower(key); if (!(k in ctx::req)) return awk::result_ng("ParseError", "missing " key); return awk::result_ok_make(ctx::req[k]) }
function body(            k) { k = "body"; if (!(k in ctx::req)) return awk::result_ng("ParseError", "missing body"); return awk::result_ok_make(ctx::req[k]) }

# --- Response helpers ---

function json(data) {
  awk::json(ctx::res, data)
  return 1
}
function json_raw(data) {
  awk::json_raw(ctx::res, data)
  return 1
}
function text(data)          { awk::text(ctx::res, data);        return 1 }
function html(data)          { awk::html(ctx::res, data);        return 1 }
function render(tpl, d)      { awk::render(ctx::res, tpl, d);   return 1 }
function redirect(url, c)    { awk::redirect(ctx::res, url, c); return 1 }
function status(code)        { awk::status(ctx::res, code);     return 1 }
function set_header(name, v) { awk::header(ctx::res, name, v);  return 1 }

function req_form(key,    k) { k = "form:" key; if (!(k in ctx::req)) return awk::result_ng("ParseError", "missing " key); return awk::result_ok_make(ctx::req[k]) }
function req_json(        k) { k = "body"; if (!(k in ctx::req)) return awk::result_ng("ParseError", "missing body"); return awk::result_ok_make(ctx::req[k]) }

BEGIN {
    _CTX_ROUTES["req.form"]     = "ctx::req_form";   _CTX_ARITY["req.form"]     = 1
    _CTX_ROUTES["req.json"]     = "ctx::req_json";   _CTX_ARITY["req.json"]     = 0
    _CTX_ROUTES["req.query"]    = "ctx::query";      _CTX_ARITY["req.query"]    = 1
    _CTX_ROUTES["req.param"]    = "ctx::param";      _CTX_ARITY["req.param"]    = 1
    _CTX_ROUTES["req.header"]   = "ctx::get_header"; _CTX_ARITY["req.header"]   = 1
    _CTX_ROUTES["req.body"]     = "ctx::body";       _CTX_ARITY["req.body"]     = 0
    _CTX_ROUTES["res.html"]     = "ctx::html";       _CTX_ARITY["res.html"]     = 1
    _CTX_ROUTES["res.text"]     = "ctx::text";       _CTX_ARITY["res.text"]     = 1
    _CTX_ROUTES["res.json"]     = "ctx::json";       _CTX_ARITY["res.json"]     = 1
    _CTX_ROUTES["res.json_raw"] = "ctx::json_raw";   _CTX_ARITY["res.json_raw"] = 1
    _CTX_ROUTES["res.render"]   = "ctx::render";     _CTX_ARITY["res.render"]   = 1
    _CTX_ROUTES["res.status"]   = "ctx::status";     _CTX_ARITY["res.status"]   = 1
    _CTX_ROUTES["res.header"]   = "ctx::set_header"; _CTX_ARITY["res.header"]   = 2
    _CTX_ROUTES["res.redirect"] = "ctx::redirect";   _CTX_ARITY["res.redirect"] = 2
}

# dispatch: DSL desugar target — ctx.req.form(...) → ctx::dispatch("req.form", ...)
function dispatch(path, a1, a2, a3) {
    return hawk_dispatch::call("ctx", _CTX_ROUTES, _CTX_ARITY, path, a1, a2, a3)
}

@namespace "awk"

# _ctx_load: copy req[] and res[] into ctx:: namespace before calling handler
function _ctx_load(req, res,    k) {
  delete ctx::req
  for (k in req) ctx::req[k] = req[k]
  delete ctx::res
  for (k in res) ctx::res[k] = res[k]
}

# _ctx_save: copy ctx::res[] back into res[] after handler returns
function _ctx_save(res,    k) {
  for (k in ctx::res) res[k] = ctx::res[k]
}
