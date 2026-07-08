type Todo = {
  id: Int
}
function run(s: Str) -> Response {
  let todo: Todo = { id: 1 }
  return todo |> ctx.res.json()
}
