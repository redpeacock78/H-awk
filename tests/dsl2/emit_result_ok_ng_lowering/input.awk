function ok_case(x: Int) -> Result<Int, Error> {
  return result.ok(x)
}

function ng_case() -> Result<Int, Error> {
  return result.ng("Negative", "x must be >= 0")
}
