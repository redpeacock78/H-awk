function run(    payload) {
  delete payload
  payload["count"] = 1
  return "ok"
}
