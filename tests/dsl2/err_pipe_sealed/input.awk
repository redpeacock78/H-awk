function handler(ctx) {
  ctx.res.json(ctx.req.form("name") |> ctx.res.json())
}
