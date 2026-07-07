function handler(x: Str) -> Response {
  let m = "#{x ~ /a|>b/}"
  return ctx.res.text(m)
}
