  hawk::dispatch("app.on", "GET", "/hello", "hello_handler")
function hello_handler() {
  return ctx::dispatch("res.text", "hello")
}
