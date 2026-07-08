hawk.app.get("/", "index"); hawk.app.listen(8080)
function index() -> Response {
  return ctx.res.text("hi")
}
