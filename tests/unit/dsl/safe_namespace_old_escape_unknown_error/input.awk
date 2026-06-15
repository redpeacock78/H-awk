function handler() -> Response {
  let raw ?= ctx.req.form("title")
  return ctx.res.html(escape_html(raw))
}
