type R = Result<Untrusted<Str>, ParseError>

function get() -> R {
  return ctx.req.form("x")
}

function handler(ctx) {
  ctx.res.json(get() |> ctx.res.json())
}
