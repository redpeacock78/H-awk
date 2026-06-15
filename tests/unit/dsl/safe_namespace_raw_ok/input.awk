function handler() -> Response {
  let out: Str = "<p>Hello</p>"
  let frag = out |> safe.html.raw()
  return ctx.res.html(frag)
}
