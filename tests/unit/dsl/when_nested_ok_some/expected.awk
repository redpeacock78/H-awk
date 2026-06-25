@namespace "app"
function handler(ctx, user, name,    _ds_mc_1, n, _ds_mc_2, user, e) {
      _ds_mc_1 = find_name(user)
      if (option_some(_ds_mc_1)) {
        n = option_val(_ds_mc_1)
        return ctx::dispatch("res.text", n)
      } else {
        return ctx::dispatch("res.status", 404)
      }
  _ds_mc_2 = fetch_user(ctx)
  if (result_ok(_ds_mc_2)) {
    user = result_val(_ds_mc_2)
  } else {
    e = result_err(_ds_mc_2)
    return ctx::dispatch("res.status", 500)
  }
}
