type Point = { x: Int, y: Int }

function run() -> Response {
  let p: Point = { x: 1, y: 2 }
  return ctx.res.json(p)
}
