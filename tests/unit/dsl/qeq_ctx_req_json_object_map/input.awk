function handler() {
  let obj: JsonObject ?= ctx.req.json_object()
  return ctx.res.json(obj)
}
