function handler(body_types) {
  let body ?= ctx.req.json()
  return ctx.res.json(body)
}
