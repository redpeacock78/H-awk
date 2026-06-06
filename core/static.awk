# SPDX-License-Identifier: MIT
# core/static.awk -- 静的ファイル配信 + mime 判定 + パストラバーサル拒否
#
# API:
#   static_mime(path)            -- 拡張子から Content-Type を判定
#   static_safe_path(req_path)   -- パストラバーサル拒否 (失敗時 "")
#   static_read(path)            -- ファイル内容を文字列で返す (バイナリ未対応、MVP)
#   serve_static(req, res)       -- public/ から配信。成功時 1、見つからず 0

function static_mime(path,    ext, dot) {
  dot = match(path, /\.[^.\/]+$/)
  if (dot == 0) return "application/octet-stream"
  ext = tolower(substr(path, dot + 1))

  if (ext == "html" || ext == "htm")  return "text/html; charset=utf-8"
  if (ext == "css")                    return "text/css; charset=utf-8"
  if (ext == "js" || ext == "mjs")     return "application/javascript; charset=utf-8"
  if (ext == "json")                   return "application/json; charset=utf-8"
  if (ext == "txt" || ext == "md")     return "text/plain; charset=utf-8"
  if (ext == "svg")                    return "image/svg+xml; charset=utf-8"
  if (ext == "png")                    return "image/png"
  if (ext == "jpg" || ext == "jpeg")   return "image/jpeg"
  if (ext == "gif")                    return "image/gif"
  if (ext == "webp")                   return "image/webp"
  if (ext == "ico")                    return "image/x-icon"
  if (ext == "woff")                   return "font/woff"
  if (ext == "woff2")                  return "font/woff2"
  return "application/octet-stream"
}

function static_safe_path(req_path,    parts, n, i) {
  sub(/^\/+/, "", req_path)
  if (req_path == "") return ""
  n = split(req_path, parts, "/")
  for (i = 1; i <= n; i++) {
    if (parts[i] == "" || parts[i] == "." || parts[i] == "..") return ""
  }
  return req_path
}

function static_read(path,    line, out, first) {
  if (LIBS_LOADED["binary"]) {
    return hawk_bin_read(path)
  }
  if (path ~ /\.(png|jpe?g|gif|webp|ico|woff2?)$/) {
    log_error("static_read: binary file requested but libs/binary not loaded: " path)
  }
  out = ""
  first = 1
  while ((getline line < path) > 0) {
    out = out (first ? "" : "\n") line
    first = 0
  }
  close(path)
  return out
}

# req["path"] を見て public/ 配下にあれば res にセット。
# 成功時 1、未存在 0。読込エラー (権限など) は 500 を res にセットして 1。
function serve_static(req, res,    safe, full, mime, cmd) {
  if (req["method"] != "GET" && req["method"] != "HEAD") return 0
  safe = static_safe_path(req["path"])
  if (safe == "") return 0
  full = "public/" safe

  cmd = "test -f " _shellquote(full) " && test -r " _shellquote(full)
  if (system(cmd) != 0) return 0

  mime = static_mime(full)
  res["status"] = 200
  res["header:content-type"] = mime

  if (LIBS_LOADED["binary"] && _static_is_binary_mime(mime)) {
    res["_binary_path"] = full
    res["body"] = ""
  } else {
    res["body"] = (req["method"] == "HEAD") ? "" : static_read(full)
  }
  return 1
}

function _static_is_binary_mime(mime) {
  return (index(mime, "image/") == 1) \
      || (index(mime, "font/") == 1)  \
      || (mime == "application/octet-stream")
}
