function ok_case(x) {
  return result_ok_make(x)
}

function ng_case() {
  return result_ng("Negative", "x must be >= 0")
}
