BEGIN {
  hawk::dispatch("app.on", "GET,POST", "/api", "handler")
  hawk::dispatch("app.all", "/", "catchall")
}
