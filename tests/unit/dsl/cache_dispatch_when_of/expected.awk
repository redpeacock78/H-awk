function probe(k,    _ds_mc_1, v, _ds_mc_2, r, e) {
    _ds_mc_2 = cache::dispatch("get", k)
    if (result_ok(_ds_mc_2)) {
      r = result_val(_ds_mc_2)
        _ds_mc_1 = r
        if (option_some(_ds_mc_1)) {
          v = option_val(_ds_mc_1)
          return cache::dispatch("get", v)
        } else {
          return cache::dispatch("get", k)
        }
    } else {
      e = result_err(_ds_mc_2)
      return cache::dispatch("get", k)
    }
}
