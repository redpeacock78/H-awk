function a(s: Str) -> Response {
  let items: List<Int> ?= json.decode<List<Int>>(s)
  return ctx.res.json(items)
}
function b(s: Str) -> Response {
  let items: List<Int> ?= json.decode<List<Int>>(s)
  return ctx.res.json(items)
}
