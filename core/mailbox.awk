# SPDX-License-Identifier: MIT
# core/mailbox.awk -- FIFO transport
@namespace "mailbox"

function path(pid) {
  return ENVIRON["HAWK_RUN_DIR"] "/mailbox/" pid ".fifo"
}

function _reply_path(ref_val) {
  return ENVIRON["HAWK_RUN_DIR"] "/reply/" ref_val ".fifo"
}

function ensure(pid,    p) {
  p = path(pid)
  if (system("test -p \"" p "\"") != 0)
    system("mkfifo \"" p "\"")
}

function send(pid, encoded,    p, cmd) {
  p = path(pid)
  if (system("test -p \"" p "\"") != 0) return 0
  cmd = "echo " (shell_quote(encoded)) " > \"" p "\" &"
  system(cmd)
  return 1
}

function call(pid, encoded, timeout_ms,    reply_fifo, ref_val, out, line, sec, cmd) {
  delete out
  if (!message::decode(encoded, out)) return ""
  ref_val    = out["ref"]
  reply_fifo = _reply_path(ref_val)
  system("mkfifo \"" reply_fifo "\"")
  sec = int((timeout_ms + 999) / 1000)
  cmd = "bash -c 'read -t " sec " line < " shell_quote(reply_fifo) " && printf \"%s\\n\" \"$line\"'"
  if ((cmd | getline line) > 0) {
    close(cmd)
    system("rm -f \"" reply_fifo "\"")
    return line
  }
  close(cmd)
  system("rm -f \"" reply_fifo "\"")
  return ""
}

function reply(reply_to, encoded) {
  system("echo " (shell_quote(encoded)) " > \"" reply_to "\" &")
}

function shell_quote(s,    r) {
  r = s
  gsub(/'/, "'\\''" , r)
  return "'" r "'"
}

@namespace "awk"
