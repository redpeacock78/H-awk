function need_int(x: Int) -> Response {
  return ctx.res.status(x)
}

function need_str(x: Str) -> Response {
  return ctx.res.text(x)
}

function fetch() -> Result<Int, Str> {
}

function handler() {
  when fetch() of
    ok x:
      return need_int(x)
    ng x:
      return need_str(x)
  end
}
