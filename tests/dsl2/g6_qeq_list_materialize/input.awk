function handler() -> Response {
  let items: List<Int> ?= json.decode<List<Int>>("[1,2,3]")
  return ctx.res.json(items)
}
