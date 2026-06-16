BEGIN {
  hawk.app.get("/", "index")
  hawk.app.listen(8080)
}

function index() {
  return ctx.res.text("ok")
}
