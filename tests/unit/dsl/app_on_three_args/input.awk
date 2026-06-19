hawk.app.on("GET", "/hello", "hello_handler")
function hello_handler() -> Response {
  return ctx.res.text("hello")
}
