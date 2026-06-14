function handler(    _ds_tc_1, title) {
  _ds_tc_1 = ctx::dispatch("req.form", "title")
  if (!result_ok(_ds_tc_1)) {
    return ctx::dispatch("res.status", 500)
  }
  title = result_val(_ds_tc_1)
}
