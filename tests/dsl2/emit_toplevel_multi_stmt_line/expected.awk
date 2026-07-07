  hawk::dispatch("app.get", "/", "index")
  hawk::dispatch("app.listen", 8080)
function index() {
  return ctx::dispatch("res.text", "hi")
}
