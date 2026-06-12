function process(items) {
  let result = []
  if (length(items) > 0) {
    for (i in items) {
      result[i] = hawk.app.get(items[i], "cb")
    }
  }
}
