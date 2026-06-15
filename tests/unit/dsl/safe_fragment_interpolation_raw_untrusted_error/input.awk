function handler() -> Response {
  let raw ?= ctx.req.form("title")
  return safe.html.fragment("<p>#{raw}</p>") |> ctx.res.html()
}
