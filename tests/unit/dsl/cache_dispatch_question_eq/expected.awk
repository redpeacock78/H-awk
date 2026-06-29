function load(k,    _ds_tc_1, opt, _ds_err_type__ds_tc_1, _ds_mc_1, v) {
    _ds_tc_1 = cache::dispatch("get", k)
    if (!result_ok(_ds_tc_1)) {
    _ds_err_type__ds_tc_1 = awk::result_err_type(_ds_tc_1)
    if (_ds_err_type__ds_tc_1 == "ParseError") return ctx::dispatch("res.status", 400)
    if (_ds_err_type__ds_tc_1 == "AuthError") return ctx::dispatch("res.status", 401)
    if (_ds_err_type__ds_tc_1 == "NotFoundError") return ctx::dispatch("res.status", 404)
    return ctx::dispatch("res.status", 500)
    }
    opt = result_val(_ds_tc_1)
    _ds_mc_1 = opt
    if (option_some(_ds_mc_1)) {
      v = option_val(_ds_mc_1)
      return cache::dispatch("get", v)
    } else {
      return cache::dispatch("get", k)
    }
}
