# H-awk core entry point.
#
# 依存順:
#   util       -- 共通ユーティリティ (他全てが依存)
#   json       -- request.awk の json body parse が依存
#   tsv        -- ハンドラから使う組込みヘルパー
#   template   -- response.awk の render() が依存
#   static     -- router の 404 fallback が呼ぶ
#   request    -- raw → req[]
#   response   -- res[] + wire format
#   router     -- ROUTES + dispatch
#   plugin     -- hook 登録 + call_hooks
#   http       -- END でリッスンループ起動

@include "core/util.awk"
@include "core/json.awk"
@include "core/tsv.awk"
@include "core/template.awk"
@include "core/static.awk"
@include "core/request.awk"
@include "core/response.awk"
@include "core/router.awk"
@include "core/plugin.awk"
@include "core/http.awk"
