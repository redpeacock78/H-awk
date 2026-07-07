function handler() -> Response {
  let d: Dict<Str, Int> = {}
  return d |> ctx.res.json()
}
