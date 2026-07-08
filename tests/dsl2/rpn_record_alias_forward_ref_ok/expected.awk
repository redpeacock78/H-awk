function run(    t) {
  delete t
  t["id"] = "1"
  return json(res, t)
}

function TodoAlias(val) { if (type::accepts("Todo", val)) return val; return result_ng("TypeError:TodoAlias", "expected Todo, got " val) }
