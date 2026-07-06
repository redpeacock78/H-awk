function f(s: Str) -> Str {
  return s
}

function handler(ctx) -> Response {
  return ctx.res.text("#{f("x")}")
}
