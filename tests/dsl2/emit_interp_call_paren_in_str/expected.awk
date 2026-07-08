function handler() {
  return ctx::dispatch("res.html", safe::dispatch("html.fragment", sprintf("%s", safe::dispatch("html.raw", "("))))
}
