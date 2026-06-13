function normalize(text) {
  return text
}

function handler(    result) {
  result = normalize(ctx::dispatch("req.form", "title"))
}
