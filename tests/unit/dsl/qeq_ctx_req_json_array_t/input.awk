function handler() {
  let xs: Array ?= ctx.req.json<Array>()
  return ctx.res.json(xs)
}
