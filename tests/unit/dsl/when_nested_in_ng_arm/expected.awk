@namespace "app"
function handler(ctx, user, fallback,    _ds_mc_1, outer, _ds_mc_2, inner) {
  _ds_mc_1 = fetch_user(ctx)
  if (result_ok(_ds_mc_1)) {
    user = result_val(_ds_mc_1)
    return ctx::dispatch("res.text", user)
  } else {
    outer = result_err(_ds_mc_1)
    _ds_mc_2 = recover_user(outer)
    if (result_ok(_ds_mc_2)) {
      fallback = result_val(_ds_mc_2)
      return ctx::dispatch("res.text", fallback)
    } else {
      inner = result_err(_ds_mc_2)
      return ctx::dispatch("res.status", 500)
    }
  }
}
