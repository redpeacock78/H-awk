BEGIN {
  hawk::dispatch("app.get", "/", "cb")
  x = "hawk.app.get is a method"
  # hawk.app.post should not transform
  y = hawk::dispatch("app.get", "/other", "cb2")
}
