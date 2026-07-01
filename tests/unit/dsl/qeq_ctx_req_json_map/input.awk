function handler() {
  let body ?= ctx.req.json()
  return ctx.res.json(body)
}
