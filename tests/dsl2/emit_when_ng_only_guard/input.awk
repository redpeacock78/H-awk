type MyErr = Error

function f(x: Int) -> Result<Int, MyErr> {
  return result.ok(x)
}

function g() -> Response {
  when f(1) of
    ng e:
      return ctx.res.text("err")
  end
  return ctx.res.text("after")
}
