#!/bin/bash
#===============================================================================
# lint.sh — 演習パック自身の静的解析(シェルスクリプトの品質チェック)
#
# 使い方:
#   ./tools/lint.sh
#
# 何をするか:
#   1. すべてのシェルスクリプトに構文エラーがないか確認する(bash -n)
#   2. shellcheck があれば、バグになりやすい書き方を検出する
#
# 静的解析ツール(shellcheck)とは:
#   シェルスクリプト専用の解析ツール。「クォート忘れ」「未定義変数」など、
#   実行しないと気づきにくい問題を指摘してくれる。案件No.6のCI/CDでも
#   同じツールをパイプラインに組み込んでいる。
#     インストール: sudo apt install -y shellcheck
#
# 注意:
#   work/ 配下(学習者が編集するファイル)は対象外。
#   雛形の段階では「まだ使っていない変数」などの警告が出るのが当然のため。
#===============================================================================

set -u

EX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$EX_ROOT" || exit 1

# 日本語コメントを含むファイルを扱うため、UTF-8ロケールを明示する
export LC_ALL="${LC_ALL:-C.UTF-8}"

fail=0

#-------------------------------------------------------------------------------
# 対象ファイルを集める
#-------------------------------------------------------------------------------
mapfile -t OWN_FILES < <(
    {
        printf '%s\n' "check.sh"
        find tools lib -name '*.sh' -type f
        find . -path './ex*/answer/*.sh' -type f
        find . -path './ex*/tests/*.sh' -type f
    } | sed 's|^\./||' | sort -u
)

mapfile -t WORK_FILES < <(find . -path './ex*/work/*.sh' -type f | sed 's|^\./||' | sort)

echo "=== 1. 構文チェック (bash -n) ==="
for f in "${OWN_FILES[@]}" "${WORK_FILES[@]}"; do
    if ! bash -n "$f" 2>/tmp/lint_err.$$; then
        echo "  NG: $f"
        sed 's/^/      /' /tmp/lint_err.$$
        fail=1
    fi
done
rm -f /tmp/lint_err.$$
[[ "$fail" -eq 0 ]] && echo "  OK: $(( ${#OWN_FILES[@]} + ${#WORK_FILES[@]} )) ファイルすべて構文エラーなし"

echo ""
echo "=== 2. 静的解析 (shellcheck) ==="
if ! command -v shellcheck > /dev/null 2>&1; then
    echo "  スキップ: shellcheck がインストールされていません。"
    echo "  (sudo apt install -y shellcheck でインストールできます)"
else
    if shellcheck --external-sources --severity=warning "${OWN_FILES[@]}"; then
        echo "  OK: ${#OWN_FILES[@]} ファイルすべて警告なし"
    else
        fail=1
    fi
fi

echo ""
if [[ "$fail" -ne 0 ]]; then
    echo "結果: 問題が見つかりました。上のメッセージを確認してください。"
    exit 1
fi
echo "結果: 問題なし"
exit 0
