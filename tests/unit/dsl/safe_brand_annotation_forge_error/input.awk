function handler() -> Response {
  let raw ?= ctx.req.form("title")
  let safe: HtmlEscapedStr = raw
  return ctx.res.html(safe)
}
