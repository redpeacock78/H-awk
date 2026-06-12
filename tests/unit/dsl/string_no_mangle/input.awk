BEGIN {
  hawk.app.get("/", "cb")
  x = "hawk.app.get is a method"
  # hawk.app.post should not transform
  y = hawk.app.get("/other", "cb2")
}
