# SPDX-License-Identifier: MIT
# core/mailbox.awk -- FIFO transport
@namespace "mailbox"

function _fs_key(s,    k) {
  k = s
  gsub(/[^[:alnum:]_.-]/, "_", k)
  return k
}

function path(pid,    rd) {
  rd = ENVIRON["HAWK_RUN_DIR"]
  if (rd == "") return ""
  return rd "/mailbox/" _fs_key(pid) ".fifo"
}

function _reply_path(ref_val,    rd) {
  rd = ENVIRON["HAWK_RUN_DIR"]
  if (rd == "") return ""
  return rd "/reply/" _fs_key(ref_val) ".fifo"
}

function ensure(pid,    p, rd) {
  p = path(pid)
  if (p == "") return
  rd = ENVIRON["HAWK_RUN_DIR"]
  system("mkdir -p " shell_quote(rd "/mailbox"))
  if (system("test -p -- " shell_quote(p)) != 0)
    system("mkfifo -- " shell_quote(p))
}

function send(pid, encoded,    p, cmd) {
  p = path(pid)
  if (p == "") return 0
  if (system("test -p -- " shell_quote(p)) != 0) return 0
  cmd = "echo " (shell_quote(encoded)) " > " shell_quote(p) " &"
  system(cmd)
  return 1
}

function wait_reply(ref_val, timeout_ms,    reply_fifo, line, sec, cmd, rd) {
  reply_fifo = _reply_path(ref_val)
  if (reply_fifo == "") return ""
  rd = ENVIRON["HAWK_RUN_DIR"]
  system("mkdir -p " shell_quote(rd "/reply"))
  system("mkfifo -- " shell_quote(reply_fifo))
  sec = int((timeout_ms + 999) / 1000)
  cmd = "HAWK_REPLY_FIFO=" shell_quote(reply_fifo) " bash -c 'read -t " sec " line < \"$HAWK_REPLY_FIFO\" && printf \"%s\\n\" \"$line\"'"
  if ((cmd | getline line) > 0) {
    close(cmd)
    system("rm -f -- " shell_quote(reply_fifo))
    return line
  }
  close(cmd)
  system("rm -f -- " shell_quote(reply_fifo))
  return ""
}

function reply(reply_to, encoded) {
  if (reply_to == "") return
  system("echo " (shell_quote(encoded)) " > " shell_quote(reply_to) " &")
}

function shell_quote(s,    r) {
  r = s
  gsub(/'/, "'\\''" , r)
  return "'" r "'"
}

@namespace "awk"
