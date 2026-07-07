BEGIN {
  _ds_tc_1 = env::dispatch("get", "PORT")
  hawk::dispatch("app.listen", (_ds_tc_1 != "" ? _ds_tc_1 : 8080))
}
