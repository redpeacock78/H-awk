@namespace "app"
function handler(ctx, user, fallback,    _ds_mc_1, fallback, inner, _ds_mc_2, user, outer) {
  _ds_mc_2 = fetch_user(ctx)
  if (result_ok(_ds_mc_2)) {
    user = result_val(_ds_mc_2)
    return ctx::dispatch("res.text", user)
  } else {
    outer = result_err(_ds_mc_2)
      _ds_mc_1 = recover_user(outer)
      if (result_ok(_ds_mc_1)) {
        fallback = result_val(_ds_mc_1)
        return ctx::dispatch("res.text", fallback)
      } else {
        inner = result_err(_ds_mc_1)
        return ctx::dispatch("res.status", 500)
      }
  }
}
