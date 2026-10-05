#!/bin/sh
# tests/run.sh 的规范模板。原样复制；utils 自身使用专用入口
# 仅负责引导：定位已有的 utils 检出目录，然后委托全部策略
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)

config=${XDG_CONFIG_HOME:-$HOME/.config}/${NVIM_APPNAME:-nvim}
data=${XDG_DATA_HOME:-$HOME/.local/share}/${NVIM_APPNAME:-nvim}

# 显式发现根必须是目录；拼写错误时绝不静默忽略
for key in VV_TEST_VENDOR_ROOT VV_TEST_LAZY_ROOT VV_TEST_PACK_ROOT; do
  eval "value=\${$key-}"
  if [ -n "$value" ] && [ ! -d "$value" ]; then
    printf 'vv-test: %s=%s: directory missing\n' "$key" "$value" >&2
    exit 1
  fi
done

if [ -n "${VV_UTILS:-}" ]; then
  selected=$VV_UTILS
else
  selected=
  for candidate in \
    "${VV_TEST_VENDOR_ROOT:-$repo/..}/vv-utils.nvim" \
    "$repo/../vv-utils.nvim" "$config/vendors/vv-utils.nvim" \
    "${VV_TEST_LAZY_ROOT:-$data/lazy}/vv-utils.nvim" \
    "${VV_TEST_PACK_ROOT:-$data/site}"/pack/*/start/vv-utils.nvim \
    "${VV_TEST_PACK_ROOT:-$data/site}"/pack/*/opt/vv-utils.nvim \
    "$config"/pack/*/start/vv-utils.nvim "$config"/pack/*/opt/vv-utils.nvim; do
    [ -d "$candidate" ] || continue
    selected=$candidate
    break
  done
fi

if [ -z "$selected" ] || [ ! -f "$selected/dev/test/run.sh" ] || [ ! -f "$selected/dev/test/paths.sh" ]; then
  printf 'vv-test: VV_UTILS=%s: shared dev/test entry missing; install/check out vv-utils.nvim or set VV_UTILS=/absolute/checkout\n' "$selected" >&2
  exit 1
fi

VV_UTILS=$(CDPATH= cd -- "$selected" && pwd -P)
export VV_UTILS

exec sh "$VV_UTILS/dev/test/run.sh" "$repo" "$@"
