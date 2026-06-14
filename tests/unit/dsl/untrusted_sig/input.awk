function handler() -> Response {
  let raw ?= ctx.req.json()
  return ctx.res.status(200)
}
