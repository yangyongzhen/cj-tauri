#!/usr/bin/env bash
# e2e/test-ohos-capabilities.sh — 鸿蒙真机 E2E：探针应用 ohos-capabilities 全插件断言
#
# 用法：bash scripts/e2e/test-ohos-capabilities.sh
#   - 在非 Windows 宿主上默认跳过（真机取证依赖 Windows 侧的 hdc + DevEco 签名）；
#     CI/取证时设 CJ_TAURI_E2E_REQUIRE=windows 可让「错机」变成失败。
#   - 前置：真机在线（hdc list targets 非空）、DevEco 自动签名已配置（build-hap.sh 的三道前置）。
#     CANGJIE_STDX_OHOS 未导出时按 ~/.cangjie/stdx/cangjie-stdx-ohos-*/dynamic/stdx 自动探测。
#
# 证据：dist/e2e-evidence/windows-ohos-capabilities.json（断言命中次数、运行时版本、UTC 时间）
# 驱动的是 examples/ohos/ohos-capabilities 探针应用（鸿蒙侧的能力位/插件探针，页面自跑全量断言、
# 经 probeLog 命令把每一行写进设备 hilog tag CjProbe）——本脚本只负责「装机、流式抓 hilog、
# 断言计数、证据落盘」，探针页是唯一断言来源，改页面不用动本脚本。
# 对端 mock（mqtt broker / redis）用本仓自带的 mock，经 hdc rport 反向转发（AGENTS §4：
# 设备出网非 443/80 端口被拦，公网 broker 实测 connect timeout，取证对端必须走 rport）。
set -u

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

e2e_require_platform windows
e2e_begin "ohos-capabilities"

PROJ="$E2E_ROOT/examples/ohos/ohos-capabilities"
OHOS="$PROJ/targets/ohos"
HAP="$OHOS/entry/build/default/outputs/default/entry-default-signed.hap"
BUNDLE="${CJ_E2E_BUNDLE:-com.yang.testcj}"
ABILITY="${CJ_E2E_ABILITY:-EntryAbility}"
E2E_NOTE="鸿蒙探针全插件断言（caps/http/fs/mqtt/redis/ws/log/sqlite/store/clipboard/menu），两轮启动覆盖 store 跨重启持久化"

# ------------------------------------------------------------------ 0) hdc 与设备
# hdc 路径：PATH 优先，否则探 DevEco 常见安装位（本机是 D:\oh\DevEcoStudio）。
HDC="${CJ_E2E_HDC:-hdc}"
if ! command -v "$HDC" >/dev/null 2>&1; then
    for cand in "D:/oh/DevEcoStudio/sdk/default/openharmony/toolchains/hdc.exe" \
                "C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe" \
                "D:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe"; do
        if [ -f "$cand" ]; then HDC="$cand"; break; fi
    done
fi
if ! command -v "$HDC" >/dev/null 2>&1 && [ ! -f "$HDC" ]; then
    e2e_fail "找不到 hdc（设 CJ_E2E_HDC=<绝对路径> 或把它加进 PATH）"
    exit 1
fi
targets="$("$HDC" list targets 2>/dev/null | grep -v '^\[Empty\]' | grep -c . || true)"
if [ "${targets:-0}" -eq 0 ]; then
    e2e_fail "没有在线的真机（hdc list targets 为空）——连接设备后重跑"
    exit 1
fi
e2e_info "hdc=$HDC 设备在线 targets=$targets"

# ------------------------------------------------------------------ 1) 构建（产物不比源码旧才跳过）
# 页面/清单/业务源码任一比 hap 新就重建；assets 同步在 build-hap.sh 里（先清再拷）。
STALE=0
if [ -f "$HAP" ]; then
    newest_src="$(find "$PROJ/assets" "$PROJ/src" "$E2E_ROOT/src" -type f -newer "$HAP" 2>/dev/null | head -1)"
    [ -n "$newest_src" ] && STALE=1
else
    STALE=1
fi
if [ "${CJ_E2E_SKIP_BUILD:-0}" = "1" ]; then
    e2e_info "CJ_E2E_SKIP_BUILD=1，跳过构建（用现有 hap）"
elif [ "$STALE" = "1" ]; then
    if [ -z "${CANGJIE_STDX_OHOS:-}" ]; then
        auto_stdx="$(ls -d "$HOME"/.cangjie/stdx/cangjie-stdx-ohos-*/dynamic/stdx 2>/dev/null | sort -V | tail -1)"
        [ -n "$auto_stdx" ] || { e2e_fail "CANGJIE_STDX_OHOS 未导出且 ~/.cangjie/stdx 下探测不到鸿蒙版 stdx"; exit 1; }
        export CANGJIE_STDX_OHOS="$auto_stdx"
        e2e_info "自动探测 CANGJIE_STDX_OHOS=$CANGJIE_STDX_OHOS"
    fi
    build_log="$E2E_ROOT/dist/e2e-evidence/ohos-capabilities.build.log"
    if ( cd "$OHOS" && bash build-hap.sh ) >"$build_log" 2>&1; then
        e2e_info "hap 构建成功（日志 $build_log）"
    else
        e2e_fail "hap 构建失败，看 $build_log 的第一个稳定错误块"
        exit 1
    fi
else
    e2e_info "hap 比源码新，跳过构建"
fi
[ -f "$HAP" ] || { e2e_fail "hap 产物不存在：$HAP"; exit 1; }

# ------------------------------------------------------------------ 2) 对端 mock + rport 转发
# mock 都只听 127.0.0.1；hdc rport 是「设备侧监听 → 转发到 PC」（fport 方向相反且撞 PC 本地端口）。
# 跨轮取证 mock 必须当轮新起：转发在而对端进程死了会得到 Connection reset by peer。
MOCK_PIDS=()
start_mock() {
    "$@" >>"$E2E_ROOT/dist/e2e-evidence/ohos-capabilities.mock.log" 2>&1 &
    MOCK_PIDS+=($!)
}
start_mock python "$E2E_ROOT/examples/mqtt-client/mock-broker.py" --port 18830
start_mock python "$E2E_ROOT/examples/redis-client/mock-redis.py" --port 6379
sleep 1
"$HDC" rport tcp:18830 tcp:18830 >/dev/null 2>&1 || e2e_info "rport 18830 建立失败（mqtt 断言会红）"
"$HDC" rport tcp:6380 tcp:6379 >/dev/null 2>&1 || e2e_info "rport 6380 建立失败（redis 断言会红）"
cleanup_mocks() {
    local p
    for p in "${MOCK_PIDS[@]:-}"; do
        [ -n "$p" ] && kill "$p" >/dev/null 2>&1
    done
    "$HDC" shell "aa force-stop $BUNDLE" >/dev/null 2>&1
}
trap cleanup_mocks EXIT

# ------------------------------------------------------------------ 3) 装机 + 两轮启动（流式 hilog 进证据日志）
if ! "$HDC" install -r "$HAP" >/dev/null 2>&1; then
    e2e_fail "hdc install 失败——签名过期或设备断连（hap=$HAP）"
    exit 1
fi
"$HDC" shell "aa force-stop $BUNDLE" >/dev/null 2>&1
sleep 1

# 流式抓 hilog：探针断言只有设备侧 hilog 一个出口（应用 stderr 不进 hilog，AGENTS §4）。
# 注意抓取进程的 cwd 别放在构建输出目录里——它会占住目录，下一轮 --clean 报 Device or resource busy。
"$HDC" shell hilog >>"$E2E_LOG" 2>&1 &
HILOG_PID=$!
sleep 1
"$HDC" shell "aa start -a $ABILITY -b $BUNDLE" >/dev/null 2>&1 || { e2e_fail "拉起应用失败"; exit 1; }
# 探针页启动即自跑全量断言；等最后一条 http 断言（页面探针顺序的末段）出现
e2e_wait_log "PASS http post status=200" 90 || { kill "$HILOG_PID" 2>/dev/null; exit 1; }
"$HDC" shell "aa force-stop $BUNDLE" >/dev/null 2>&1
kill "$HILOG_PID" 2>/dev/null
sleep 2

# 第二轮：store 的 persist-key 在第一轮 clear 后已重写，重启后探针应报跨重启存活
"$HDC" shell hilog >>"$E2E_LOG" 2>&1 &
HILOG_PID=$!
sleep 1
"$HDC" shell "aa start -a $ABILITY -b $BUNDLE" >/dev/null 2>&1
e2e_wait_log "PASS store persist" 90 || { kill "$HILOG_PID" 2>/dev/null; exit 1; }
sleep 8
"$HDC" shell "aa force-stop $BUNDLE" >/dev/null 2>&1
kill "$HILOG_PID" 2>/dev/null

# ------------------------------------------------------------------ 4) 断言（断言名禁含冒号/反引号——证据层按第一个冒号拆 name:needle）
# needle 取「稳定且足以判别」的边界：不夹耗时/端口/临时路径/时间戳（AGENTS §4）。
e2e_assert "能力位菜单置一"       "PASS cap menu expect=true actual=true"
e2e_assert "能力位全表对账"       "caps 5/5 bits match expectation"
e2e_assert "菜单勾选回写"         "PASS menu setChecked view.sidebar=true"
e2e_assert "剪贴板写入"           "PASS clipboard write cj-tauri-clip-"
e2e_assert "剪贴板读平台降级"     "SKIP clipboard read denied-by-platform"
e2e_assert "http https 走系统栈"  "PASS http https-get status=200"
e2e_assert "http 明文照旧"        "PASS http plain-get status=200"
e2e_assert "http post 回显"       "PASS http post status=200 echoed=true"
e2e_assert "http 流式如实拒绝"    "PASS http postStream rejected"
e2e_assert "fs 写读链"            "PASS fsR write true"
e2e_assert "fs 越界拒绝"          "PASS fsR outside-scope rejected"
e2e_assert "fs deny 命中拒绝"     "PASS fsR deny-path rejected"
e2e_assert "mqtt 连接"            "PASS mqtt connect"
e2e_assert "mqtt 订阅"            "PASS mqtt subscribe"
e2e_assert "mqtt 发布"            "PASS mqtt publish"
e2e_assert "mqtt 自收回环"        "PASS mqtt round-trip got="
e2e_assert "redis 连接"           "PASS redis connect"
e2e_assert "redis 读写对账"       "PASS redis get round-trip expect=cj-redis-"
e2e_assert "ws 降级如实拒绝"      "PASS ws degraded-connect rejected"
e2e_assert "ws 越界拒绝"          "PASS ws outside-scope rejected"
e2e_assert "log 路径降级"         "PASS log path empty="
e2e_assert "log 写入降级"         "PASS log write-degraded=false"
e2e_assert "sqlite 建库建表"      "PASS sqlite exec"
e2e_assert "sqlite 回读对账"      "PASS sqlite query round-trip"
e2e_assert "sqlite 越界拒绝"      "PASS sqlite outside-scope rejected"
e2e_assert "store 读写链"         "PASS store get round-trip"
e2e_assert "store 跨重启持久化"   "PASS store persist survived-restart"

# 负向检查：探针任何一条 FAIL 都不能进证据（e2e_assert 只判 needle 存在，负向在这里收口）
fails="$(grep -a -c 'CjProbe: FAIL' "$E2E_LOG" || true)"
if [ "${fails:-0}" -ne 0 ]; then
    grep -a 'CjProbe: FAIL' "$E2E_LOG" | head -5 >&2
    e2e_fail "探针有 ${fails} 条 FAIL 行（明细见上方与 $E2E_LOG）"
    exit 1
fi

e2e_finalize
