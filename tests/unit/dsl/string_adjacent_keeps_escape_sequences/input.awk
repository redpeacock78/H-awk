function handler() -> Response {
  let s: Str = "line1\n" "line2\t" "line3"
  return ctx.res.text(s)
}
