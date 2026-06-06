# core/http.awk -- /inet/tcp listener + request ループ
#
# bin/hawk が gawk -f hawk.awk -f <plugins...> -f app.awk として起動する。
# app.awk の BEGIN で GET / POST 等のルート登録が走った後、この core の END で
# サーバーループを開始する。
#
# シャットダウン:
#   bin/hawk が SIGTERM 受信 → gawk へ中継。
#   gawk は次の read で EOF / EINTR を見て HAWK_SHUTDOWN=1 を立て、ループを抜ける。

END {
  if (!("HAWK_NO_SERVE" in ENVIRON)) {
    # ENVIRON 経由設定 (.env)
    HAWK_PORT             = ENVIRON["HAWK_PORT"]             ? ENVIRON["HAWK_PORT"]             + 0 : 8080
    HAWK_MAX_HEADER_SIZE  = ENVIRON["HAWK_MAX_HEADER_SIZE"]  ? ENVIRON["HAWK_MAX_HEADER_SIZE"]  + 0 : 8192
    HAWK_MAX_BODY_SIZE    = ENVIRON["HAWK_MAX_BODY_SIZE"]    ? ENVIRON["HAWK_MAX_BODY_SIZE"]    + 0 : 1048576
    HAWK_REQUEST_TIMEOUT  = ENVIRON["HAWK_REQUEST_TIMEOUT"]  ? ENVIRON["HAWK_REQUEST_TIMEOUT"]  + 0 : 30
    HAWK_DEV              = (ENVIRON["DEV"] == "1")

    plugin_discover()
    if (PLUGIN_REGISTER_ERROR) {
      log_error("plugin registration failed, exiting.")
      exit 1
    }
    call_hooks("init")

    log_info(sprintf("H-awk listening on http://0.0.0.0:%d", HAWK_PORT))

    HAWK_SHUTDOWN = 0
    http_serve()

    log_info("shutting down")
    call_hooks("shutdown")
  }
}

function http_serve(    sock, line, headers_raw, body, content_length, raw, hdr_size, req, res, dispatch_ok, start_ms, ok) {
  sock = "/inet/tcp/" HAWK_PORT "/0/0"
  PROCINFO[sock, "READ_TIMEOUT"] = HAWK_REQUEST_TIMEOUT * 1000

  while (!HAWK_SHUTDOWN) {
    # 1. ヘッダ部読込 (空行 = CRLF CRLF まで)
    headers_raw = ""
    hdr_size = 0
    while (1) {
      ok = (sock |& getline line)
      if (ok <= 0) {
        # ピア閉鎖 / シグナル / タイムアウト
        break
      }
      sub(/\r$/, "", line)
      if (line == "") break
      headers_raw = headers_raw line "\r\n"
      hdr_size += length(line) + 2
      if (hdr_size > HAWK_MAX_HEADER_SIZE) {
        http_send_simple(sock, 431, "Request Header Fields Too Large")
        close(sock)
        headers_raw = ""
        break
      }
    }

    if (headers_raw == "") {
      close(sock)
      continue
    }

    start_ms = now_ms()

    # 2. Content-Length 確認 → body 読込
    body = ""
    content_length = http_header_get(headers_raw, "Content-Length") + 0
    if (content_length > HAWK_MAX_BODY_SIZE) {
      http_send_simple(sock, 413, "Payload Too Large")
      close(sock)
      continue
    }
    if (content_length > 0) {
      body = http_read_body(sock, content_length)
    }

    # 3. 完成 raw → request_parse
    raw = headers_raw "\r\n" body
    delete req
    delete res
    delete _ARR_COUNT
    res["status"] = 200
    if (!request_parse(raw, req)) {
      http_send_simple(sock, 400, "Bad Request")
      close(sock)
      continue
    }

    # 4. pre_request hook
    if (call_hooks("pre_request", req, res) == 1) {
      http_send(sock, res, req, start_ms)
      close(sock)
      continue
    }

    # 5. ルーティング → 静的 → 404 / 405
    dispatch_ok = router_dispatch(req, res)
    if (dispatch_ok == 0) {
      if (!serve_static(req, res)) {
        status(res, 404)
        text(res, "Not Found")
      }
    }
    # dispatch_ok == -1 (405) と 1 (ハンドラ実行済) は何もしない

    # 6. post_request hook
    call_hooks("post_request", req, res)

    # 7. 送信
    http_send(sock, res, req, start_ms)
    close(sock)
  }

  close(sock)
}

function http_read_body(sock, n,    line, ok, prev_rs) {
  if (n <= 0) return ""
  # Use RS = ".{n}" so gawk reads exactly n bytes as the record separator.
  # gawk's RT variable then holds the matched bytes (the body content).
  # This avoids blocking on getline when the body has no trailing newline
  # (e.g. application/x-www-form-urlencoded sent by curl -d).
  prev_rs = RS
  RS = sprintf(".{%d}", n)
  ok = (sock |& getline line)
  line = RT   # RT holds the text that matched RS
  RS = prev_rs
  return substr(line, 1, n)
}

function http_header_get(headers_raw, name,    lines, n, i, k, lname) {
  lname = to_lower(name)
  n = split(headers_raw, lines, "\r\n")
  for (i = 1; i <= n; i++) {
    if (lines[i] == "") continue
    k = index(lines[i], ":")
    if (k == 0) continue
    if (to_lower(trim(substr(lines[i], 1, k - 1))) == lname) {
      return trim(substr(lines[i], k + 1))
    }
  }
  return ""
}

function http_send(sock, res, req, start_ms,    wire, dur, ts) {
  if (res["sent"]) return    # 二重送信防止 (send() 明示呼出 後)
  wire = response_wire(res)
  printf "%s", wire |& sock
  fflush(sock)
  res["sent"] = 1

  dur = now_ms() - start_ms
  ts  = strftime("%Y-%m-%dT%H:%M:%S%z")
  printf "%s\tINFO\t%s\t%s\t%d\t%d\n", ts, req["method"], req["path"], res["status"], dur
  fflush()
}

function http_send_simple(sock, code, body,    res) {
  delete res
  status(res, code)
  text(res, body)
  printf "%s", response_wire(res) |& sock
  fflush(sock)
}
