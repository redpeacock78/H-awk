function handler() -> Response {
  let x: Str = "foo"
  let s: Str = x
  return ctx.res.text(s)
}
