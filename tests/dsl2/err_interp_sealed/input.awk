function handler(ctx) -> Str {
  return "#{ctx.req.form("name")}"
}
