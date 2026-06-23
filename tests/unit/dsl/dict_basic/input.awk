function run() -> Response {
  let scores: Dict<Str, Int> = {}
  scores["one"] = 1
  return ctx.res.json(scores)
}
