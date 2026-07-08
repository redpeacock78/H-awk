type L = List<Int>

function handler() -> Response {
  let xs: L = []
  return ctx.res.json(xs)
}
