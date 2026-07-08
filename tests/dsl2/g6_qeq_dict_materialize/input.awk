function handler(s: Str) -> Response {
  let d: Dict<Str, Int> ?= json.decode<Dict<Str, Int>>(s)
  return ctx.res.json(d)
}
