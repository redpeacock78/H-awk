function normalize(text) {
  return text
}
function handler() {
  return ctx::dispatch("res.text", normalize("1"))
}
