function run(    xs) {
  delete xs
  xs["__json_type"] = "array"
  xs[1] = 1
  xs[2] = 2
  return json(res, xs)
}
