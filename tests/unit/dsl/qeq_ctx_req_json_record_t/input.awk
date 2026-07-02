type Todo = {
  id: Str
  done: Bool
}

function handler() {
  let todo: Todo ?= ctx.req.json<Todo>()
  return ctx.res.json(todo)
}
