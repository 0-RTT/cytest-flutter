#!/usr/bin/env bash
# 取 Windows 版引擎二进制到 windows/bin/（不进 git，体积太大）。
#
#   xray.exe     —— 走代理 / 抓取 / 本地测试的代理内核（XTLS/Xray-core）
#   pipeline.exe —— 三阶段测试引擎（由 engine/pipeline.go 编译，需要 Go）
#
# 用法：bash tool/fetch_win_engine.sh [xray|pipeline|all]
#
# 代理：本机默认走 v2rayN 的 socks5；CI 里用 CYTEST_HTTP_PROXY='' 走直连。
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="windows/bin"
mkdir -p "$OUT"
TARGET="${1:-all}"

PROXY="${CYTEST_HTTP_PROXY-socks5h://127.0.0.1:10808}"
CURL_PROXY=()
if [[ -n "$PROXY" ]]; then
  CURL_PROXY=(-x "$PROXY")
fi

fetch_xray() {
  if [[ -f "$OUT/xray.exe" ]]; then
    echo "xray.exe 已存在，跳过"
    return
  fi

  echo "== 下载 Xray-core (windows-64)"
  local api="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
  local url
  if [[ -n "${XRAY_VERSION:-}" ]]; then
    # CI 里用钉死的版本，避免每次构建拿到不同的上游最新版（漂移）。
    url="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-windows-64.zip"
  else
    url=$(curl -sS --ssl-no-revoke --max-time 30 "${CURL_PROXY[@]}" "$api" |
      python -c "import json,sys;d=json.load(sys.stdin);print(next(a['browser_download_url'] for a in d['assets'] if a['name']=='Xray-windows-64.zip'))")
  fi

  local tmp
  tmp=$(mktemp -d)
  curl -sSL --ssl-no-revoke --max-time 600 "${CURL_PROXY[@]}" -o "$tmp/x.zip" "$url"
  unzip -o -q "$tmp/x.zip" xray.exe -d "$tmp"
  mv "$tmp/xray.exe" "$OUT/xray.exe"
  rm -rf "$tmp"
  "$OUT/xray.exe" version | head -1
}

fetch_pipeline() {
  if [[ -f "$OUT/pipeline.exe" ]]; then
    echo "pipeline.exe 已存在，跳过"
    return
  fi
  if ! command -v go >/dev/null 2>&1; then
    echo "缺少 Go，无法编译 pipeline.exe（装 Go 1.22+ 后重跑）" >&2
    return 1
  fi

  echo "== 编译 engine/pipeline.go → windows/amd64"
  # engine/ 里没有 go.mod（单文件、纯标准库），必须 GO111MODULE=off 且显式给文件名；
  # 用 `.` 会因为「不在模块内」直接报错。
  ( cd engine && GO111MODULE=off GOOS=windows GOARCH=amd64 CGO_ENABLED=0 \
      go build -trimpath -ldflags "-s -w" -o "../$OUT/pipeline.exe" pipeline.go )
  ls -l "$OUT/pipeline.exe"
}

case "$TARGET" in
  xray) fetch_xray ;;
  pipeline) fetch_pipeline ;;
  all) fetch_xray; fetch_pipeline ;;
  *) echo "用法: $0 [xray|pipeline|all]" >&2; exit 2 ;;
esac

echo "== $OUT"
ls -l "$OUT"
