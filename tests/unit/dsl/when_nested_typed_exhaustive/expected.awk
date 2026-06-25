function ErrA(msg) { return result_ng("ErrA", msg) }
function ErrB(msg) { return result_ng("ErrB", msg) }

function fetch_user(ctx) {
}

function save_user(user) {
}

function handler(ctx, user, saved,    _ds_mc_1, saved, e, _ds_mc_2, user, outer) {
  _ds_mc_2 = fetch_user(ctx)
  if (result_ok(_ds_mc_2)) {
    user = result_val(_ds_mc_2)
      _ds_mc_1 = save_user(user)
      if (result_ok(_ds_mc_1)) {
        saved = result_val(_ds_mc_1)
        return ctx::dispatch("res.text", saved)
      } else if (result_err_type(_ds_mc_1) == "ErrA") {
        e = result_err(_ds_mc_1)
        return ctx::dispatch("res.status", 409)
      } else if (result_err_type(_ds_mc_1) == "ErrB") {
        e = result_err(_ds_mc_1)
        return ctx::dispatch("res.status", 410)
      }
  } else {
    outer = result_err(_ds_mc_2)
    return ctx::dispatch("res.status", 500)
  }
}
