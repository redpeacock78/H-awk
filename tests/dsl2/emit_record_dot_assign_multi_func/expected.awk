function a(    todo) {
  delete todo
  todo["done:bool"] = 0
  todo["done:bool"] = 1
  return "ok"
}

function b(    todo) {
  delete todo
  todo["done:bool"] = 1
  todo["done:bool"] = 0
  return "x"
}
