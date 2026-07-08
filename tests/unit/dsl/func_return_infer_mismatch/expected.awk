function get_count() {
  return 42
}

function handler(    msg) {
  msg = get_count()
  return ctx::dispatch("res.text", msg)
}
