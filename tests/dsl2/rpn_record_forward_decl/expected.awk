function run(    todo) {
  delete todo
  todo["id"] = 1
  return json(res, todo)
}
