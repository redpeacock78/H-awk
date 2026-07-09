type MyErr = Error

function f(n: Int) -> Result<Int, MyErr> {
  return result.ok(n)
}

function g() -> Response {
  let v: Int = 1
  when f(1) of
    some v:
      return ctx.res.text("ok")
    ng e:
      return ctx.res.text("err")
  end
}
