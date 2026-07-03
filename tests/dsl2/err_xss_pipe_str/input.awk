function handler() -> Response {
  return "<p>Hello</p>" |> ctx.res.html()
}
