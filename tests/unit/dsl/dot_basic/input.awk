BEGIN {
  hawk.app.get("/", "index")
  hawk.app.post("/todos", "todo_add")
}
