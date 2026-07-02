function run() -> Void {
  let n: Int = 1 + 2
  # 暗黙連結の CONCAT 意味論は未実装（"a" は孤立ノードとなり AST に接続されない）。
  # この let は STRLIT 基本規則（Str）の確認のみが目的。真の CONCAT 還元（複数
  # オペランドの意味的連結）は後続タスクで対応する。
  let s: Str = "a" "b"
}
