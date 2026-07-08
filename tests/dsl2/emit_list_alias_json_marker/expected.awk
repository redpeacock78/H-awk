function L(val) { if (type::accepts("List<Int>", val)) return val; return result_ng("TypeError:L", "expected List<Int>, got " val) }

function handler(    xs) {
  delete xs
  xs["__json_type"] = "array"
  return json(res, xs)
}
