function parse(s: Str) -> Str {
  classify: validator
  return s
}

function handler(ctx) {
  let raw ?= ctx.req.form("name")
  ctx.res.render(raw |> parse())
}
