@namespace "app"
function handler(ctx, a, b, c,    _ds_mc_1, _ds_mc_2, _ds_mc_3, e1, e0) {
  _ds_mc_1 = outer()
  if (result_ok(_ds_mc_1)) {
    a = result_val(_ds_mc_1)
    _ds_mc_2 = middle(a)
    if (result_ok(_ds_mc_2)) {
      b = result_val(_ds_mc_2)
      _ds_mc_3 = inner(b)
      if (option_some(_ds_mc_3)) {
        c = option_val(_ds_mc_3)
        return ctx::dispatch("res.text", c)
      } else {
        return ctx::dispatch("res.status", 404)
      }
    } else {
      e1 = result_err(_ds_mc_2)
      return ctx::dispatch("res.status", 500)
    }
  } else {
    e0 = result_err(_ds_mc_1)
    return ctx::dispatch("res.status", 502)
  }
}
