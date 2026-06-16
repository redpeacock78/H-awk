function handler() {
  when ctx.req.json() of
    ok:
      return ctx.res.status(200)
    ng err:
      return ctx.res.status(500)
  end
}
