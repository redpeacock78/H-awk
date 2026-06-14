function handler() -> Response {
  let s: Str = "foo" "bar"
  return ctx.res.text(s)
}
