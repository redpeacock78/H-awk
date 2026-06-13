BEGIN {
  hawk.app.get("/todos", "todo_list")
  hawk.app.post("/todos", "todo_add")
}
