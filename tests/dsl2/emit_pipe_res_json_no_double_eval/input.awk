function id(x: Int) -> Int {
  return x
}
function inc() -> Int {
  return 1
}
function run() -> Response {
  return ctx.res.json(inc() |> id())
}
