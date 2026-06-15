function handler(    name, msg) {
  name = "hawk"
  msg = sprintf("hello %s!", name)
  return ctx::dispatch("res.text", msg)
}
