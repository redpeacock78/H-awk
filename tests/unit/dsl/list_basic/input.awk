function run() -> Response {
  let xs: List<Int> = []
  xs[1] = 1
  xs[2] = 2
  return ctx.res.json(xs)
}
