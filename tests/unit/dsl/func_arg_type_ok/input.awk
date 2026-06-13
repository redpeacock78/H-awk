function normalize(text: Str) -> Str {
  return text
}

function handler() {
  let result: Str = normalize(ctx.req.form("title"))
}
