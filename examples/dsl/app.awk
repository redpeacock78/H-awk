# Example hawk app using DSL dot-notation and let declarations
# Run with: bin/hawk examples/dsl/app.awk

BEGIN {
  hawk.app.get("/", "todo_index")
  hawk.app.get("/todos/:id", "todo_show")
  hawk.app.post("/todos", "todo_add")
  hawk.app.delete("/todos/:id", "todo_delete")
}

function todo_index() {
  let items = []
  let i
  let out = ""
  for (i in TODOS) {
    out = out TODOS[i] "\n"
  }
  hawk.res.text(out == "" ? "No todos" : out)
}

function todo_show() {
  let id = ctx.req.param("id")
  let item = TODOS[id]
  hawk.res.text(item != "" ? item : "Not found")
}

function todo_add() {
  let title = ctx.req.form("title")
  let id = length(TODOS) + 1
  TODOS[id] = title
  hawk.res.status(201)
  hawk.res.text("Created: " title)
}

function todo_delete() {
  let id = ctx.req.param("id")
  delete TODOS[id]
  hawk.res.text("Deleted")
}
