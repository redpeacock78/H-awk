function handler() -> Response {
  let raw ?= ctx.req.form("title")
  let safe = escape_html(raw)
  return ctx.res.html(safe)
}
