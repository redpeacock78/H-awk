# SPDX-License-Identifier: MIT
function test_tsv_append_and_read(   row, out, n, tmpfile) {
  tmpfile = "/tmp/hawk_tsv_test_" PROCINFO["pid"] ".tsv"
  system("rm -f " tmpfile)

  delete row
  row["id"]    = "1"
  row["title"] = "buy milk"
  append_tsv(tmpfile, row)

  delete row
  row["id"]    = "2"
  row["title"] = "tab\there"
  append_tsv(tmpfile, row)

  delete out
  n = read_tsv(tmpfile, out)
  assert_eq(n, 2, "tsv: read count")
  assert_eq(out[1, "id"], "1", "tsv: read row1 id")
  assert_eq(out[1, "title"], "buy milk", "tsv: read row1 title")
  assert_eq(out[2, "title"], "tab\there", "tsv: tab escape round-trip")

  system("rm -f " tmpfile)
}

function test_tsv_find(   row, found, tmpfile) {
  tmpfile = "/tmp/hawk_tsv_find_" PROCINFO["pid"] ".tsv"
  system("rm -f " tmpfile)

  delete row; row["id"] = "1"; row["name"] = "alice"; append_tsv(tmpfile, row)
  delete row; row["id"] = "2"; row["name"] = "bob";   append_tsv(tmpfile, row)

  delete row
  found = find_tsv(tmpfile, "id", "2", row)
  assert_eq(found, 1, "tsv: find found")
  assert_eq(row["name"], "bob", "tsv: find result")

  delete row
  found = find_tsv(tmpfile, "id", "99", row)
  assert_eq(found, 0, "tsv: find not-found")

  system("rm -f " tmpfile)
}

function test_tsv_delete_update(   row, out, n, tmpfile) {
  tmpfile = "/tmp/hawk_tsv_du_" PROCINFO["pid"] ".tsv"
  system("rm -f " tmpfile)

  delete row; row["id"] = "1"; row["name"] = "a"; append_tsv(tmpfile, row)
  delete row; row["id"] = "2"; row["name"] = "b"; append_tsv(tmpfile, row)
  delete row; row["id"] = "3"; row["name"] = "c"; append_tsv(tmpfile, row)

  delete row
  row["name"] = "B"
  n = update_tsv(tmpfile, "id", "2", row)
  assert_eq(n, 1, "tsv: update count")

  delete row
  find_tsv(tmpfile, "id", "2", row)
  assert_eq(row["name"], "B", "tsv: update applied")

  n = delete_tsv(tmpfile, "id", "1")
  assert_eq(n, 1, "tsv: delete count")

  delete out
  n = read_tsv(tmpfile, out)
  assert_eq(n, 2, "tsv: post-delete count")

  system("rm -f " tmpfile)
}
