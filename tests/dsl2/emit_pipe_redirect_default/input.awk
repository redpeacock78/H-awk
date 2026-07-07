function f(url: Str) -> Response {
  return url |> ctx.res.redirect()
}
