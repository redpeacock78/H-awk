function double(x) {
  return x * 2
}

function run() -> Response {
  return ctx.res.text(double(21))
}
