BEGIN {
  hawk.app.listen(env.get("PORT") ?? 8080)
}
