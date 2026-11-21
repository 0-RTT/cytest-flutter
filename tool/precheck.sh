#!/usr/bin/env bash
# 推送前的本地闸门：与 CI 的 Analyze 同口径（warning 致命、info 不算）。
# 2026-11-21 踩过：只跑了 lib 的 analyze，漏掉 lib/ui/home.dart 里一个
# unused_local_variable，CI 直接红（本地 analyze 用的是旧时间点）。
set -euo pipefail
source toolchain.sh >/dev/null 2>&1
echo "== flutter analyze (warning 致命)"
if flutter analyze --no-fatal-infos | grep -E "^(warning|error) [-•]"; then
  echo "✗ 有 warning/error，停止推送"
  exit 1
fi
echo "✓ 0 warning / 0 error"
echo "== flutter test"
flutter test 2>&1 | tail -3
