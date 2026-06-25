type ReadError = Error
type ParseError = Error

function fetch() -> Result<Str, Result<Int, ReadError | ParseError>> {
}

function handler() {
  when fetch() of
    ok x:
      return ctx.res.text(x)
    ng x:
      x = x
  end

  when x of
    ok value:
      return ctx.res.status(value)
    ng e<ReadError>:
      return ctx.res.status(400)
  end
}
