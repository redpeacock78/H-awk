function f(s: Str) -> Str {
  return s
}

function handler(ctx) -> Str {
  return "#{f("a\"b") ctx.req.form("name")}"
}
