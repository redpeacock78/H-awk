BEGIN {
  hawk.app.on("GET,POST", "/api", "handler")
  hawk.app.all("/", "catchall")
}
