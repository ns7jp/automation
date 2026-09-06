#!/bin/bash
#===============================================================================
# make-index.sh — 演習一覧の表を自動生成して README.md に反映する
#
# 使い方:
#   ./tools/make-index.sh            README.md の一覧を書き換える
#   ./tools/make-index.sh --stdout   標準出力に表示するだけ(書き換えない)
#   ./tools/make-index.sh --check    README.md が最新かどうかだけ確認する(CI用)
#
# 何をするか:
#   各演習の meta.env を読み込み、Markdownの表を組み立てて
#   README.md の次のマーカーの間を差し替える。
#
#     <!-- BEGIN:EXERCISE-INDEX -->
#     <!-- END:EXERCISE-INDEX -->
#
#   演習を追加・変更したときに、一覧の更新漏れを防ぐための小さな自動化。
#   「手作業を自動化する」という、このリポジトリ全体のテーマの実例でもある。
#===============================================================================

set -u

EX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$EX_ROOT" || exit 1

README="${EX_ROOT}/README.md"
BEGIN_MARK="<!-- BEGIN:EXERCISE-INDEX -->"
END_MARK="<!-- END:EXERCISE-INDEX -->"

MODE="write"
case "${1:-}" in
    --stdout) MODE="stdout" ;;
    --check)  MODE="check" ;;
    "")       MODE="write" ;;
    *)
        echo "エラー: 不明なオプションです: $1" >&2
        exit 1
        ;;
esac

#-------------------------------------------------------------------------------
# 表を組み立てる
#-------------------------------------------------------------------------------
build_table() {
    local dir last_stage=""
    local EX_ID EX_TITLE EX_STAGE EX_STAGE_NAME EX_LEVEL EX_TIME EX_SKILL EX_PROJECT EX_TARGET

    for dir in "$EX_ROOT"/ex[0-9][0-9]-*/; do
        [[ -f "${dir}meta.env" ]] || continue
        EX_ID=""; EX_TITLE=""; EX_STAGE=""; EX_STAGE_NAME=""
        EX_LEVEL=""; EX_TIME=""; EX_SKILL=""; EX_PROJECT=""; EX_TARGET=""
        # shellcheck source=/dev/null
        source "${dir}meta.env"

        if [[ "$EX_STAGE" != "$last_stage" ]]; then
            [[ -n "$last_stage" ]] && echo ""
            echo "### ステージ${EX_STAGE}: ${EX_STAGE_NAME}"
            echo ""
            echo "| No. | 演習 | 難易度 | 目安 | 身につく力 |"
            echo "|---|---|---|---|---|"
            last_stage="$EX_STAGE"
        fi

        printf '| ex%s | [%s](%s/README.md) | %s | %s | %s |\n' \
            "$EX_ID" "$EX_TITLE" "$(basename "$dir")" "$EX_LEVEL" "$EX_TIME" "$EX_SKILL"
    done
}

TABLE="$(build_table)"

if [[ -z "$TABLE" ]]; then
    echo "エラー: 演習が1件も見つかりませんでした。" >&2
    exit 1
fi

if [[ "$MODE" == "stdout" ]]; then
    printf '%s\n' "$TABLE"
    exit 0
fi

if [[ ! -f "$README" ]]; then
    echo "エラー: README.md が見つかりません: ${README}" >&2
    exit 1
fi

if ! grep -qF "$BEGIN_MARK" "$README" || ! grep -qF "$END_MARK" "$README"; then
    echo "エラー: README.md に一覧のマーカーが見つかりません。" >&2
    echo "  ${BEGIN_MARK} と ${END_MARK} を README.md に書いてください。" >&2
    exit 1
fi

#-------------------------------------------------------------------------------
# マーカーの間を差し替えた内容を組み立てる
#   awk で「開始マーカーまで」「表」「終了マーカーから最後まで」を連結する。
#-------------------------------------------------------------------------------
NEW_README="$(mktemp)"
awk -v begin_mark="$BEGIN_MARK" -v end_mark="$END_MARK" -v table="$TABLE" '
    $0 == begin_mark { print; print ""; print table; print ""; skip = 1; next }
    $0 == end_mark   { skip = 0 }
    skip != 1        { print }
' "$README" > "$NEW_README"

if [[ "$MODE" == "check" ]]; then
    if diff -q "$README" "$NEW_README" > /dev/null; then
        echo "OK: README.md の演習一覧は最新です。"
        rm -f "$NEW_README"
        exit 0
    fi
    echo "NG: README.md の演習一覧が meta.env と一致していません。" >&2
    echo "  ./tools/make-index.sh を実行して更新してください。" >&2
    diff "$README" "$NEW_README" | head -n 40 >&2
    rm -f "$NEW_README"
    exit 1
fi

mv "$NEW_README" "$README"
echo "README.md の演習一覧を更新しました。"
exit 0
