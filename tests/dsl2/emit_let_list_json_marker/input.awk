function run() -> Response {
  let xs: List<Int> = []
  xs[1] = 2
  return ctx.res.json(xs)
}
