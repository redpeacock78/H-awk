function handler() {
  when ctx.req.json() of
    ok body:
      return ctx.res.json(body)
    default err:
      return ctx.res.status(500)
  end
}
