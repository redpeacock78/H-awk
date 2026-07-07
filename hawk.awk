# SPDX-License-Identifier: MIT
# H-awk core entry point.
#
# 依存順:
#   util       -- 共通ユーティリティ (他全てが依存)
#   libs       -- libs (gawk extension) 読込状態の集約 (v0.2 追加)
#   json       -- request.awk の json body parse が依存
#   tsv        -- ハンドラから使う組込みヘルパー
#   template   -- response.awk の render() が依存
#   static     -- router の 404 fallback が呼ぶ
#   request    -- raw → req[]
#   response   -- res[] + wire format
#   router     -- ROUTES + dispatch
#   ctx        -- ctx:: namespace / Context API (Hono-style)
#   plugin     -- hook 登録 + call_hooks
#   http       -- END でリッスンループ起動

@include "core/util.awk"
@include "dsl/adt.awk"
@include "core/dispatch.awk"
@include "core/libs.awk"
@include "core/json.awk"
@include "core/url.awk"
@include "core/gzip.awk"
@include "core/tsv.awk"
@include "core/template.awk"
@include "core/static.awk"
@include "core/request.awk"
@include "core/response.awk"
@include "core/hawk.awk"
@include "core/env.awk"
@include "core/safe.awk"
@include "core/router.awk"
@include "core/ctx.awk"
@include "core/cache.awk"
@include "core/message.awk"
@include "core/objectspace.awk"
@include "core/mailbox.awk"
@include "core/proc.awk"
@include "core/plugin.awk"
@include "core/http.awk"
