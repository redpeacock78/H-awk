BEGIN {
  hawk::dispatch("app.get", "/", "cb") # hawk.app.post not here
  # let x = hawk.app.get("/skip", "cb")
  x = 1 # some.thing.here(args)
}
