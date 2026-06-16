function handler() {
  when ctx.req.json() of
    ok body:
      return ctx.res.json(body)
  end
}
