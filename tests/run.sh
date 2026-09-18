#!/bin/sh
# 每个行为测试使用独立 Neovim 进程
set -eu
tests_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
for test_file in "$tests_dir"/test_*.lua; do
  printf 'RUN: %s\n' "$(basename -- "$test_file")"
  "${NVIM_BIN:-nvim}" --headless -u NONE -l "$test_file"
done
