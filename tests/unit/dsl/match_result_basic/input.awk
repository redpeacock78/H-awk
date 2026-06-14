function handler() {
  match ctx.req.json() of
    ok body:
      return ctx.res.json(body)
    ng err:
      return ctx.res.status(500)
  end
}
