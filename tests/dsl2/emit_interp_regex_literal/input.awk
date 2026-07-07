function handler(x: Str) -> Response {
  let m = "#{x ~ /safe.html.raw()/}"
  return ctx.res.text(m)
}
