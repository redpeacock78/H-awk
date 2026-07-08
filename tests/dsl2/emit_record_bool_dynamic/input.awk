type Todo = {
  done: Bool
}
function run(flag: Bool) -> Response {
  let todo: Todo = { done: flag }
  todo.done = flag
  return ctx.res.json(todo)
}
