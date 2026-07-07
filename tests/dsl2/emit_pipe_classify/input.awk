function strip(s: Str) -> Str {
  classify: transform
  return s
}

function handler(ctx) {
  let raw ?= ctx.req.form("name")
  ctx.res.html(safe.html.escape(raw |> strip()))
}
