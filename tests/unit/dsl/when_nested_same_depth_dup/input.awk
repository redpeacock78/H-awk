@namespace "app"
function handler(    x) {
  x = lookup()
  when x of
    ok y:
      pass()
    ng y:   # ok y と ng y は許容
      pass()
  end
  when inner() of
    ng a:
      pass()
    ng a:   # 同 branch_kind の重複 → エラー
      pass()
  end
}
