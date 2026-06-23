function run() -> Response {
  let xs: List<Int> = []
  xs["foo"] = 1
  return ctx.res.json(xs)
}
