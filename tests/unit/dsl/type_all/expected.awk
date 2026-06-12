function types(    n, s, f, b) {
  n = type::coerce("42", "Int")
  s = type::coerce(123, "Str")
  f = type::coerce("3.14", "Float")
  b = type::coerce("true", "Bool")
}
