function some_user_func() -> Result<Int, ParseError> {
}

function handler() {
  let x ?= some_user_func()
  return ctx.res.text(x)
}
