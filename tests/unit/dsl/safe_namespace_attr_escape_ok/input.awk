function handler() -> Response {
  let raw ?= ctx.req.param("id")
  let attr = raw |> safe.attr.escape()
  return ctx.res.html(attr)
}
