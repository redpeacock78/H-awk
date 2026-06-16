function handler() {
  when ctx.req.json() of
    ok body:
      return ctx.res.json(body)
    default:
      return ctx.res.status(500)
  end
}
