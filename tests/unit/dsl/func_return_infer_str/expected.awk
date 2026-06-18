function greet() {
  return "hello"
}

function handler(    msg) {
  msg = greet()
  return ctx::dispatch("res.text", msg)
}
