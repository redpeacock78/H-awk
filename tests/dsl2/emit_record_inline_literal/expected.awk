function run(    p) {
  delete p
  p["x"] = 1
  p["y"] = 2
  return json(res, p)
}
