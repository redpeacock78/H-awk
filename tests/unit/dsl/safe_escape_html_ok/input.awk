function handler() -> Response {
  let raw ?= ctx.req.form("title")
  let safe = raw |> safe.html.escape()
  return ctx.res.html(safe)
}
