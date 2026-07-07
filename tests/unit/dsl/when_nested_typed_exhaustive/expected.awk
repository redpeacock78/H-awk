
function fetch_user(ctx) {
}

function save_user(user) {
}

function handler(ctx, user, saved,    _ds_mc_1, _ds_mc_2, e, outer) {
  _ds_mc_1 = fetch_user(ctx)
  if (result_ok(_ds_mc_1)) {
    user = result_val(_ds_mc_1)
    _ds_mc_2 = save_user(user)
    if (result_ok(_ds_mc_2)) {
      saved = result_val(_ds_mc_2)
      return ctx::dispatch("res.text", saved)
    } else if (awk::result_err_type(_ds_mc_2) == "ErrA") {
      e = result_err(_ds_mc_2)
      return ctx::dispatch("res.status", 409)
    } else if (awk::result_err_type(_ds_mc_2) == "ErrB") {
      e = result_err(_ds_mc_2)
      return ctx::dispatch("res.status", 410)
    }
  } else {
    outer = result_err(_ds_mc_1)
    return ctx::dispatch("res.status", 500)
  }
}
