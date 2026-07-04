function handler(ctx) -> Response {
  let raw ?= ctx.req.form("name")
  return ctx.res.html(safe.html.fragment("#{safe.html.raw("}") raw}"))
}
