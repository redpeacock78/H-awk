function double(x) {
  return x * 2
}

function run() {
  return ctx::dispatch("res.text", double(21))
}
