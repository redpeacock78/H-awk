function f(s: Str) -> Str {
  return s
}

function handler(ctx) -> Str {
  return "#{f("x") ctx.req.form("name")}"
}
