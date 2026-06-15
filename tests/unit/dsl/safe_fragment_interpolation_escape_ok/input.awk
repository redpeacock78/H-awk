function handler() -> Response {
  let raw ?= ctx.req.form("title")
  let frag = safe.html.fragment("<p>#{raw |> safe.html.escape()}</p>")
  return ctx.res.html(frag)
}
