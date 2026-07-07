BEGIN {
  hawk::dispatch("app.get", "/", "index")
  hawk::dispatch("app.post", "/todos", "todo_add")
}
