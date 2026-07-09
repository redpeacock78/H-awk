function f(    xs) {
  delete xs
  xs["__json_type"] = "array"
  xs[0] = 1
}
