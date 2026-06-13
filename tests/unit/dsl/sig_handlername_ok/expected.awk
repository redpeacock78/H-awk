BEGIN {
  hawk::dispatch("app.get", "/todos", "todo_list")
  hawk::dispatch("app.post", "/todos", "todo_add")
}
