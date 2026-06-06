# core/template.awk -- MVP テンプレート (生 HTML 読込のみ)
#
# 変数置換・ループ・分岐は v0.2 以降。MVP はファイル全文を返す薄いラッパー。
# 動的部分はユーザーが awk 文字列連結で組み立て、res["body"] に直接書き込む。

function template_read(path,    line, out, first) {
  out = ""
  first = 1
  while ((getline line < path) > 0) {
    out = out (first ? "" : "\n") line
    first = 0
  }
  close(path)
  return out
}
