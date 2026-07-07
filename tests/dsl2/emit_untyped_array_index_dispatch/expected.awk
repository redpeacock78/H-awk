function process(items,    result) {
  delete result
  if (length(items) > 0) {
    for (i in items) {
  result[i] = hawk::dispatch("app.get", items[i], "cb")
    }
  }
}
