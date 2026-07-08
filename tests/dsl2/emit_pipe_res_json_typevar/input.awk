function run(s: Str) -> Response {
  let items: List<Int> ?= json.decode<List<Int>>(s)
  return items |> ctx.res.json()
}
