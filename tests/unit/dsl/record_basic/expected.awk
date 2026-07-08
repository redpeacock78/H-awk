function run(    todo) {
  delete todo
  todo["id"] = "1"
  todo["title"] = "buy milk"
  todo["done:bool"] = 0
  return json(res, todo)
}
