
function handler(    xs) {
  delete xs
  xs["__json_type"] = "array"
  return json(res, xs)
}
