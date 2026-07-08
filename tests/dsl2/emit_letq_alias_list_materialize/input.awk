type L = List<Int>
function run(s: Str) -> Response {
  let xs ?= json.decode<L>(s)
  return ctx.res.json(xs)
}
