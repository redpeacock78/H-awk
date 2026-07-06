function handler() {
  let xs: List<Int> ?= json.decode_t("List<Int>", s)
  return ctx.res.json(xs)
}
