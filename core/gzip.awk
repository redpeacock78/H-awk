# SPDX-License-Identifier: MIT
# core/gzip.awk -- gzip compression for HTTP responses

function gzip_maybe(res, req,    body, compressed, ae, ct, status, min_size) {
  if (!LIBS_LOADED["gzip"]) return 0
  if (ENVIRON["HAWK_GZIP"] != "1") return 0

  ae = tolower(req["header:accept-encoding"])
  if (index(ae, "gzip") == 0) return 0

  status = res["status"] + 0
  if (status == 204 || status == 304) return 0
  if (status < 200 || status >= 300) return 0

  if (req["method"] == "HEAD") return 0

  if ("header:content-encoding" in res) return 0

  ct = tolower(res["header:content-type"])
  if (ct ~ /image\/(png|jpeg|webp|gif)/) return 0
  if (ct ~ /application\/(zip|gzip|pdf)/) return 0
  if (ct ~ /video\//) return 0
  if (ct ~ /audio\//) return 0

  body = res["body"]

  min_size = (ENVIRON["HAWK_GZIP_MIN_SIZE"] != "") ? (ENVIRON["HAWK_GZIP_MIN_SIZE"] + 0) : 1024
  if (length(body) < min_size) return 0

  compressed = hawk_gzip_compress(body)
  if (hawk_gzip_error() != "") return 0

  res["body"] = compressed
  res["header:content-encoding"] = "gzip"
  res["header:vary"] = "Accept-Encoding"
  res["header:content-length"] = length(compressed)
  return 1
}
