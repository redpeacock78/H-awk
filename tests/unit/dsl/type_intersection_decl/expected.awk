function Both(val) { if (type::accepts("Int&Str", val)) return val; return result_ng("TypeError:Both", "expected Int&Str, got " val) }
