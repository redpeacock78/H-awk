@namespace "app"
function handler(ctx, user, saved,    _ds_mc_1, saved, inner, _ds_mc_2, user, outer) {
  _ds_mc_2 = fetch_user(ctx)
  if (result_ok(_ds_mc_2)) {
    user = result_val(_ds_mc_2)
      _ds_mc_1 = save_user(user)
      if (result_ok(_ds_mc_1)) {
        saved = result_val(_ds_mc_1)
        return ctx::dispatch("res.text", saved)
      } else {
        inner = result_err(_ds_mc_1)
        return ctx::dispatch("res.status", 409)
      }
  } else {
    outer = result_err(_ds_mc_2)
    return ctx::dispatch("res.status", 500)
  }
}
