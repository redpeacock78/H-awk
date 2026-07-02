function handler() {
  let v: JsonScalar ?= json.decode<JsonScalar>(s)
  return ctx.res.json(v)
}
