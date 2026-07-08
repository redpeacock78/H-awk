function run() -> Response {
  let items: List<Int> ?= json.decode<List<Int>>("[1]")
  return ctx.res.json(items)
}
