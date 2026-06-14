# integration: requires desugar_match.awk @include (added in Task 4)
function handler(    _ds_mc_1, body) {
  _ds_mc_1 = ctx::dispatch("req.json")
  if (result_ok(_ds_mc_1)) {
    body = result_val(_ds_mc_1)
    return ctx::dispatch("res.json", body)
  } else {
    return ctx::dispatch("res.status", 500)
  }
}
