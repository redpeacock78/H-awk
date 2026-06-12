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

function query(key)       { return ctx::req["query:" key] }
function param(key)       { return ctx::req["params:" key] }
function get_header(key)  { return ctx::req["header:" awk::to_lower(key)] }
function body()           { return ctx::req["body"] }

# --- Response helpers ---

# json(data): set body to a pre-encoded JSON string and set content-type.
# For array-based encoding, callers should use awk::json_encode() directly.
function json(data) {
  if (!("status" in ctx::res)) ctx::res["status"] = 200
  ctx::res["header:content-type"] = "application/json; charset=utf-8"
  ctx::res["body"] = data
  return 1
}
function text(data)          { awk::text(ctx::res, data);        return 1 }
function html(data)          { awk::html(ctx::res, data);        return 1 }
function render(tpl, d)      { awk::render(ctx::res, tpl, d);   return 1 }
function redirect(url, c)    { awk::redirect(ctx::res, url, c); return 1 }
function status(code)        { awk::status(ctx::res, code);     return 1 }
function set_header(name, v) { awk::header(ctx::res, name, v);  return 1 }

# dispatch: DSL desugar target — ctx.req.form(...) → ctx::dispatch("req.form", ...)
function dispatch(path, a1, a2) {
    if (path == "req.form")     return req["form:" a1]
    if (path == "req.query")    return query(a1)
    if (path == "req.param")    return param(a1)
    if (path == "req.header")   return get_header(a1)
    if (path == "req.body")     return body()
    if (path == "res.html")     return html(a1)
    if (path == "res.text")     return text(a1)
    if (path == "res.json")     return json(a1)
    if (path == "res.render")   return render(a1, a2)
    if (path == "res.status")   return status(a1)
    if (path == "res.header")   return set_header(a1, a2)
    if (path == "res.redirect") return redirect(a1, a2)
    print "ctx::dispatch: unknown path: " path > "/dev/stderr"
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
