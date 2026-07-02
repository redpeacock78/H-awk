function handler() {
  let body: Dict<Str,Int> ?= json.decode<Dict<Str,Int>>(s)
  return ctx.res.json(body)
}
