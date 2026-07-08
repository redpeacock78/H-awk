BEGIN {
  hawk::dispatch("app.listen", env::dispatch("get", "PORT") ?? 8080)
}
