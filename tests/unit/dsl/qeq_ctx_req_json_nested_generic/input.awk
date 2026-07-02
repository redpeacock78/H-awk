function handler() {
  let xs: List<Int> ?= ctx.req.json<List<Int>>()
  return ctx.res.json(xs)
}
