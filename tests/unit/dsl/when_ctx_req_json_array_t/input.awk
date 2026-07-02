function handler() {
  when ctx.req.json<Array>() of
    ok xs:
      return ctx.res.json(xs)
    ng err:
      return ctx.res.status(500)
  end
}
