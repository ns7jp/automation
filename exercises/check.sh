#!/bin/bash
#===============================================================================
# check.sh — 演習の自動採点ツール(このパックの中心となるコマンド)
#
# 使い方:
#   ./check.sh                自分の解答(work/)を全演習ぶん採点する
#   ./check.sh 03             ex03 だけを採点する(03 / 3 / ex03 いずれも可)
#   ./check.sh 03 05 07       複数の演習をまとめて採点する
#   ./check.sh --stage 2      ステージ2の演習だけを採点する
#   ./check.sh --answer       解答例(answer/)を採点する(答え合わせ・動作確認用)
#   ./check.sh --answer 03    ex03 の解答例だけを採点する
#   ./check.sh --list         演習の一覧を表示する
#   ./check.sh --help         このヘルプを表示する
#
# 終了ステータス:
#   0 : 選んだ演習がすべて合格
#   1 : 1つ以上の演習が不合格、または引数エラー
#
# 補足:
#   採点は毎回、使い捨ての一時ディレクトリの中だけで行われます。
#   あなたのPCのユーザーやファイルが書き換えられることはありません。
#   仕組みの詳細は docs/04-self-check-guide.md を参照してください。
#===============================================================================

set -u

EX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EX_LIB="${EX_ROOT}/lib"
export EX_ROOT EX_LIB

#-------------------------------------------------------------------------------
# 色設定(端末に出力するときだけ色を付ける)
#-------------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_CYAN=$'\033[36m'; C_GRAY=$'\033[90m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_GRAY=""; C_BOLD=""; C_OFF=""
fi

MODE="work"
STAGE_FILTER=""
declare -a WANTED=()

usage() {
    sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

#-------------------------------------------------------------------------------
# 引数の解析
#-------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--answer) MODE="answer" ;;
        -w|--work)   MODE="work" ;;
        -l|--list)   MODE="list" ;;
        -s|--stage)
            shift
            STAGE_FILTER="${1:-}"
            if [[ -z "$STAGE_FILTER" ]]; then
                echo "エラー: --stage にはステージ番号を指定してください(例: --stage 2)" >&2
                exit 1
            fi
            ;;
        -h|--help)   usage; exit 0 ;;
        -*)
            echo "エラー: 不明なオプションです: $1" >&2
            echo "使い方は ./check.sh --help で確認できます。" >&2
            exit 1
            ;;
        *)
            # 3 / 03 / ex03 / ex03-server-info のいずれの書き方も受け付ける
            id="${1#ex}"
            id="${id%%-*}"
            if [[ ! "$id" =~ ^[0-9]+$ ]]; then
                echo "エラー: 演習番号の指定が不正です: $1" >&2
                exit 1
            fi
            WANTED+=("$(printf '%02d' "$((10#$id))")")
            ;;
    esac
    shift
done

#-------------------------------------------------------------------------------
# 演習ディレクトリの一覧を取得する
#-------------------------------------------------------------------------------
declare -a ALL_DIRS=()
for d in "$EX_ROOT"/ex[0-9][0-9]-*/; do
    [[ -d "$d" ]] || continue
    ALL_DIRS+=("${d%/}")
done

if [[ "${#ALL_DIRS[@]}" -eq 0 ]]; then
    echo "エラー: 演習ディレクトリ(ex01-... 形式)が見つかりません。" >&2
    echo "  ${EX_ROOT} の中で実行しているか確認してください。" >&2
    exit 1
fi

#-------------------------------------------------------------------------------
# meta.env(演習の情報ファイル)を読み込む
#-------------------------------------------------------------------------------
# shellcheck disable=SC2034  # EX_PROJECT などは meta.env の値を保持するための変数
load_meta() {
    local dir="$1"
    EX_ID=""; EX_TITLE=""; EX_STAGE=""; EX_STAGE_NAME=""
    EX_LEVEL=""; EX_TIME=""; EX_SKILL=""; EX_PROJECT=""; EX_TARGET=""
    if [[ -f "${dir}/meta.env" ]]; then
        # shellcheck source=/dev/null
        source "${dir}/meta.env"
    fi
    [[ -n "$EX_ID" ]] || EX_ID="$(basename "$dir" | sed 's/^ex\([0-9]*\).*/\1/')"
    return 0
}

#-------------------------------------------------------------------------------
# 対象にするかどうかを判定する
#-------------------------------------------------------------------------------
is_selected() {
    local id="$1" stage="$2" w
    if [[ -n "$STAGE_FILTER" && "$stage" != "$STAGE_FILTER" ]]; then
        return 1
    fi
    if [[ "${#WANTED[@]}" -eq 0 ]]; then
        return 0
    fi
    for w in "${WANTED[@]}"; do
        [[ "$w" == "$id" ]] && return 0
    done
    return 1
}

#-------------------------------------------------------------------------------
# --list: 一覧表示
#-------------------------------------------------------------------------------
if [[ "$MODE" == "list" ]]; then
    printf '%s演習一覧%s (全%d件)\n\n' "$C_BOLD" "$C_OFF" "${#ALL_DIRS[@]}"
    last_stage=""
    for dir in "${ALL_DIRS[@]}"; do
        load_meta "$dir"
        if [[ "$EX_STAGE" != "$last_stage" ]]; then
            printf '\n%sステージ%s: %s%s\n' "$C_CYAN" "$EX_STAGE" "$EX_STAGE_NAME" "$C_OFF"
            last_stage="$EX_STAGE"
        fi
        printf '  ex%s  %-10s %s\n' "$EX_ID" "$EX_LEVEL" "$EX_TITLE"
        printf '        %s目安%s / %s%s\n' "$C_GRAY" "$EX_TIME" "$EX_SKILL" "$C_OFF"
    done
    printf '\n採点するには: ./check.sh 01\n'
    exit 0
fi

#-------------------------------------------------------------------------------
# 採点の実行
#-------------------------------------------------------------------------------
if [[ "$MODE" == "answer" ]]; then
    printf '%s※ 解答例(answer/)を採点しています%s\n' "$C_YELLOW" "$C_OFF"
fi

TOTAL=0
PASSED=0
declare -a FAILED_IDS=()

for dir in "${ALL_DIRS[@]}"; do
    load_meta "$dir"
    is_selected "$EX_ID" "$EX_STAGE" || continue

    TOTAL=$((TOTAL + 1))
    dir_name="$(basename "$dir")"
    target="${dir}/${MODE}/${EX_TARGET}"

    printf '\n%s────────────────────────────────────────────────────────%s\n' "$C_GRAY" "$C_OFF"
    printf '%s ex%s %s%s  %s[ステージ%s / %s / 目安%s]%s\n' \
        "$C_BOLD" "$EX_ID" "$EX_TITLE" "$C_OFF" \
        "$C_GRAY" "$EX_STAGE" "$EX_LEVEL" "$EX_TIME" "$C_OFF"
    printf '%s 対象: exercises/%s/%s/%s%s\n' \
        "$C_GRAY" "$dir_name" "$MODE" "$EX_TARGET" "$C_OFF"
    printf '%s────────────────────────────────────────────────────────%s\n' "$C_GRAY" "$C_OFF"

    if [[ ! -f "${dir}/tests/test.sh" ]]; then
        printf '  %s✗ テストファイルがありません: %s/tests/test.sh%s\n' "$C_RED" "$dir_name" "$C_OFF"
        FAILED_IDS+=("$EX_ID")
        continue
    fi

    if EX_DIR="$dir" MODE="$MODE" TARGET="$target" \
       EX_ID="$EX_ID" EX_TITLE="$EX_TITLE" \
       bash "${dir}/tests/test.sh"; then
        PASSED=$((PASSED + 1))
    else
        FAILED_IDS+=("$EX_ID")
    fi
done

if [[ "$TOTAL" -eq 0 ]]; then
    echo "エラー: 指定に一致する演習がありませんでした。" >&2
    echo "  ./check.sh --list で演習番号を確認してください。" >&2
    exit 1
fi

#-------------------------------------------------------------------------------
# サマリ表示
#-------------------------------------------------------------------------------
printf '\n%s════════════════ 採点結果サマリ ════════════════%s\n' "$C_BOLD" "$C_OFF"
printf ' 合格: %s%d%s / %d 件\n' "$C_GREEN" "$PASSED" "$C_OFF" "$TOTAL"

if [[ "${#FAILED_IDS[@]}" -gt 0 ]]; then
    printf ' 未合格: %s%s%s\n' "$C_RED" "${FAILED_IDS[*]}" "$C_OFF"
    next_id="${FAILED_IDS[0]}"
    printf '\n 次にやること:\n'
    printf '   1. exercises/ex%s-*/README.md を読み直す\n' "$next_id"
    printf '   2. work/ の中のファイルを直す\n'
    printf '   3. ./check.sh %s で再採点する\n' "$next_id"
    printf '\n %sどうしても分からないときは docs/06-hints-and-pitfalls.md を確認し、%s\n' "$C_GRAY" "$C_OFF"
    printf ' %sそれでも進まなければ answer/ の解答例を読んで理解し、写経してから自力で書き直してください。%s\n' "$C_GRAY" "$C_OFF"
    exit 1
fi

printf '\n %s全問合格です。おつかれさまでした。%s\n' "$C_GREEN$C_BOLD" "$C_OFF"
if [[ "$MODE" == "work" ]]; then
    printf ' %s学習記録シート(docs/05-progress-sheet.md)に、詰まった点と学びを書き残しておくと%s\n' "$C_GRAY" "$C_OFF"
    printf ' %s面接で話せる素材になります。%s\n' "$C_GRAY" "$C_OFF"
fi
exit 0
