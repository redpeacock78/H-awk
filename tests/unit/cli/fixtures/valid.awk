BEGIN {
  hawk.app.get("/", "handle_index")
  hawk.app.listen(8080)
}

function handle_index() {
  return ctx.res.text("ok")
}
