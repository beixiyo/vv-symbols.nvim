# Splits 是面板尺寸调整测试 fixture，不是生产依赖
vv_test_dependency VV_TEST_SPLITS vv-splits.nvim lua/vv-splits/init.lua
vv_test_path VV_TEST_PARSERS "$VV_TEST_SITE" \
  parser/lua.so parser/luadoc.so parser/typescript.so parser/tsx.so
vv_test_runtime VV_TEST_PARSERS
# 查询文件可以随 site 提供，也可以来自已有的 treesitter 源码
if [ -n "${VV_TEST_QUERIES:-}" ] || [ -f "$VV_TEST_SITE/queries/typescript/highlights.scm" ]; then
  vv_test_path VV_TEST_QUERIES "$VV_TEST_SITE" \
    queries/lua/highlights.scm queries/lua/injections.scm queries/luadoc/highlights.scm \
    queries/typescript/highlights.scm queries/tsx/highlights.scm \
    queries/ecma/highlights.scm queries/jsx/highlights.scm
else
  vv_test_dependency VV_TEST_QUERIES nvim-treesitter \
    queries/lua/highlights.scm queries/lua/injections.scm queries/luadoc/highlights.scm \
    queries/typescript/highlights.scm queries/tsx/highlights.scm \
    queries/ecma/highlights.scm queries/jsx/highlights.scm
fi
vv_test_runtime VV_TEST_QUERIES
