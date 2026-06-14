function handler() {
  match ctx.req.json() of
    ok body:
      return ctx.res.json(body)
  end
}
