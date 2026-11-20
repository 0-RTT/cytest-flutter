#!/usr/bin/env bash
# 加载本机 Flutter/Android 工具链。
#
#   source toolchain.sh
#
# 顺序：先看 C:\cytest-toolchain\env.sh（当前机器就是这套，放 C 盘是因为 D 盘只剩 5G），
# 再回落到仓库内 .toolchain/env.sh（旧布局/别的机器）。两处都没有就报错说清怎么装。
set -e

__cytest_env=""
for __p in "/c/cytest-toolchain/env.sh" "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.toolchain/env.sh"; do
  if [ -f "$__p" ]; then
    __cytest_env="$__p"
    break
  fi
done

if [ -z "$__cytest_env" ]; then
  echo "找不到工具链：C:\\cytest-toolchain\\env.sh 和 ./.toolchain/env.sh 都不存在" >&2
  echo "安装方法见 docs 或项目记忆里的「.toolchain 三处补丁」一节" >&2
  unset __cytest_env __p
  return 1 2>/dev/null || exit 1
fi

# shellcheck disable=SC1090
. "$__cytest_env"
unset __cytest_env __p
