# core/tsv.awk -- TSV ヘルパー
#
# データモデル: 1 行目はヘッダ (列名 TSV)、2 行目以降がレコード。
# エスケープ: 値内のタブ → "\t" (2文字)、改行 → "\n"、バックスラッシュ → "\\"。
# 読込時に逆変換する。
#
# API:
#   append_tsv(path, row)              -> 1=success, 0=failure
#   read_tsv(path, out)                -> 件数 (out[i,"<列名>"] = 値)
#   find_tsv(path, key, val, row)      -> 1=found, 0=not-found
#   delete_tsv(path, key, val)         -> 削除件数
#   update_tsv(path, key, val, update) -> 更新件数

function _tsv_escape(v) {
  gsub(/\\/, "\\\\", v)
  gsub(/\t/, "\\t",  v)
  gsub(/\n/, "\\n",  v)
  gsub(/\r/, "\\r",  v)
  return v
}

function _tsv_unescape(v,    out, i, n, c, nc) {
  out = ""
  n = length(v)
  for (i = 1; i <= n; i++) {
    c = substr(v, i, 1)
    if (c == "\\" && i < n) {
      nc = substr(v, i + 1, 1)
      if      (nc == "t")  out = out "\t"
      else if (nc == "n")  out = out "\n"
      else if (nc == "r")  out = out "\r"
      else if (nc == "\\") out = out "\\"
      else                 out = out nc
      i++
    } else {
      out = out c
    }
  }
  return out
}

function _tsv_read_header(path, header,    line, i, n, parts) {
  delete header
  if ((getline line < path) <= 0) {
    close(path)
    return 0
  }
  close(path)
  n = split(line, parts, "\t")
  for (i = 1; i <= n; i++) header[i] = parts[i]
  header["_count"] = n
  return n
}

function append_tsv(path, row,    header, n, i, line, key, names, ncols) {
  # ヘッダ未存在 → row のキーをヘッダとして書出
  if ((getline line < path) <= 0) {
    close(path)
    n = 0
    for (key in row) names[++n] = key
    line = ""
    for (i = 1; i <= n; i++) line = line (i > 1 ? "\t" : "") names[i]
    print line > path
    close(path)
    ncols = n
    for (i = 1; i <= n; i++) header[i] = names[i]
  } else {
    close(path)
    ncols = _tsv_read_header(path, header)
  }

  line = ""
  for (i = 1; i <= ncols; i++) {
    line = line (i > 1 ? "\t" : "") _tsv_escape(header[i] in row ? row[header[i]] : "")
  }
  print line >> path
  close(path)
  return 1
}

function read_tsv(path, out,    line, header, ncols, idx, i, parts, n) {
  delete out
  ncols = _tsv_read_header(path, header)
  if (ncols == 0) return 0

  idx = 0
  n = 0
  while ((getline line < path) > 0) {
    n++
    if (n == 1) continue   # skip header
    idx++
    split(line, parts, "\t")
    for (i = 1; i <= ncols; i++) {
      out[idx, header[i]] = _tsv_unescape(parts[i])
    }
  }
  close(path)
  return idx
}

function find_tsv(path, key, val, row,    line, header, ncols, i, parts, n) {
  delete row
  ncols = _tsv_read_header(path, header)
  if (ncols == 0) return 0

  n = 0
  while ((getline line < path) > 0) {
    n++
    if (n == 1) continue
    split(line, parts, "\t")
    for (i = 1; i <= ncols; i++) {
      if (header[i] == key && _tsv_unescape(parts[i]) == val) {
        # match — fill row
        for (i = 1; i <= ncols; i++) row[header[i]] = _tsv_unescape(parts[i])
        close(path)
        return 1
      }
    }
  }
  close(path)
  return 0
}

function delete_tsv(path, key, val,    line, header, ncols, i, parts, n, count, tmppath) {
  ncols = _tsv_read_header(path, header)
  if (ncols == 0) return 0

  tmppath = path ".tmp"
  count = 0
  n = 0
  while ((getline line < path) > 0) {
    n++
    if (n == 1) {
      print line > tmppath
      continue
    }
    split(line, parts, "\t")
    for (i = 1; i <= ncols; i++) {
      if (header[i] == key && _tsv_unescape(parts[i]) == val) {
        count++
        line = ""    # mark for skip
        break
      }
    }
    if (line != "") print line > tmppath
  }
  close(path)
  close(tmppath)
  system(sprintf("mv -- %s %s", _shellquote(tmppath), _shellquote(path)))
  return count
}

function update_tsv(path, key, val, update,    line, header, ncols, i, parts, n, count, tmppath, j, row, newline) {
  ncols = _tsv_read_header(path, header)
  if (ncols == 0) return 0

  tmppath = path ".tmp"
  count = 0
  n = 0
  while ((getline line < path) > 0) {
    n++
    if (n == 1) {
      print line > tmppath
      continue
    }
    split(line, parts, "\t")
    delete row
    for (i = 1; i <= ncols; i++) row[header[i]] = _tsv_unescape(parts[i])

    if (row[key] == val) {
      for (j in update) row[j] = update[j]
      count++
    }

    newline = ""
    for (i = 1; i <= ncols; i++) {
      newline = newline (i > 1 ? "\t" : "") _tsv_escape(row[header[i]])
    }
    print newline > tmppath
  }
  close(path)
  close(tmppath)
  system(sprintf("mv -- %s %s", _shellquote(tmppath), _shellquote(path)))
  return count
}

function _shellquote(s) {
  gsub(/'/, "'\\''", s)
  return "'" s "'"
}
