#!/usr/bin/env bash
# =====================================================================
# daily-summary.sh
# 改善案件No.3: アラート過多の改善 - 日次サマリ生成スクリプト
#
# ■ 何をするスクリプトか
#   全件記録(records.jsonl)から指定日の分を集計し、
#   「その日1日、どんな通知が何件あったか」をまとめた
#   Markdownレポートを作り、Slackへ1件だけ通知する。
#
# ■ なぜ必要か
#   この改善では P3(記録のみ)の通知を即時通知しない。
#   しかし、それは「捨てる」という意味ではない。
#   毎朝この日次サマリを1件だけ見れば、P3も含めて
#   「昨日何が起きていたか」が必ず分かるようにする。
#   これがあるからこそ、安心して即時通知を減らせる。
#
#   通知を減らす改善で最も危険なのは、「見えなくなったこと」に
#   誰も気づかないまま運用が続くこと。日次サマリは、その歯止めになる。
#
# ■ 使い方
#   ./daily-summary.sh                     # 昨日分を集計して通知
#   ./daily-summary.sh --date 2026-09-01   # 日付を指定
#   ./daily-summary.sh --no-notify         # ファイル生成のみ(通知しない)
#
# ■ 依存コマンド: bash 4.0以降, jq, awk, sort, date, curl
# =====================================================================

set -uo pipefail

AR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=common.sh
source "${AR_SCRIPT_DIR}/common.sh"

AR_CONFIG_FILE="${AR_CONFIG_FILE:-${AR_SCRIPT_DIR}/alert-router.conf}"
if [[ ! -f "$AR_CONFIG_FILE" ]]; then
    printf '[ERROR] 設定ファイルが見つかりません: %s\n' "$AR_CONFIG_FILE" >&2
    exit 1
fi
# shellcheck source=alert-router.conf
source "$AR_CONFIG_FILE"

TARGET_DATE=""
DO_NOTIFY="true"
OUT_FILE=""

usage() {
    cat <<'USAGE'
使い方: daily-summary.sh [オプション]

オプション:
  --date <YYYY-MM-DD>  集計対象日(省略時は昨日)
  --out <ファイル>     レポートの出力先(省略時は設定のサマリ用ディレクトリ)
  --no-notify          Slackへの通知を行わない(レポート生成のみ)
  -h, --help           このヘルプを表示する
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --date) TARGET_DATE="${2:-}"; shift 2 ;;
        --out)  OUT_FILE="${2:-}"; shift 2 ;;
        --no-notify) DO_NOTIFY="false"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf '[ERROR] 不明なオプションです: %s\n' "$1" >&2; usage >&2; exit 1 ;;
    esac
done

ar_require_command jq awk sort date || exit 1

if [[ -z "$TARGET_DATE" ]]; then
    TARGET_DATE="$(date -d 'yesterday' '+%Y-%m-%d')"
fi
if [[ -z "$OUT_FILE" ]]; then
    OUT_FILE="${AR_SUMMARY_DIR}/summary-${TARGET_DATE}.md"
fi

if [[ ! -f "$AR_RECORD_FILE" ]]; then
    ar_log ERROR "記録ファイルが見つかりません: ${AR_RECORD_FILE}"
    exit 1
fi

if ! ar_load_rules "$AR_RULES_FILE"; then
    exit 1
fi

mkdir -p "$(dirname "$OUT_FILE")"

# ---------------------------------------------------------------------
# 記録(JSON Lines)から対象日の分だけを取り出す
#
# jq の select(.date == $d) で対象日の行だけに絞り、
# @tsv で必要な項目だけをタブ区切りに変換する。
# JSONのままシェルで扱うと引用符の処理が面倒なので、
# 「jqで必要な列だけタブ区切りに落としてから集計する」のが定石。
# ---------------------------------------------------------------------
RECORDS="$(jq -r --arg d "$TARGET_DATE" \
    'select(.date == $d) | [.severity, .action, .rule_id, .source, .host, .adjust] | @tsv' \
    "$AR_RECORD_FILE")"

declare -A SEVERITY_HITS=()
declare -A ACTION_HITS=()
declare -A RULE_HITS=()
declare -A SOURCE_HITS=()
declare -A P3_HITS=()
declare -A ADJUST_HITS=()
TOTAL=0

if [[ -n "$RECORDS" ]]; then
    while IFS=$'\t' read -r severity action rule_id source_name host adjust; do
        [[ -z "$severity" ]] && continue
        SEVERITY_HITS["$severity"]=$(( ${SEVERITY_HITS["$severity"]:-0} + 1 ))
        ACTION_HITS["$action"]=$(( ${ACTION_HITS["$action"]:-0} + 1 ))
        RULE_HITS["$rule_id"]=$(( ${RULE_HITS["$rule_id"]:-0} + 1 ))
        SOURCE_HITS["$source_name"]=$(( ${SOURCE_HITS["$source_name"]:-0} + 1 ))
        [[ "$severity" == "P3" ]] && P3_HITS["$rule_id"]=$(( ${P3_HITS["$rule_id"]:-0} + 1 ))
        [[ "$adjust" != "none" ]] && ADJUST_HITS["$adjust"]=$(( ${ADJUST_HITS["$adjust"]:-0} + 1 ))
        TOTAL=$((TOTAL + 1))
    done <<<"$RECORDS"
fi

# ホスト名は本サマリでは使っていないが、入力列の説明として受け取っている
: "${host:-}"

if [[ "$TOTAL" -eq 0 ]]; then
    ar_log WARN "${TARGET_DATE} の記録が1件もありません。サマリは生成しません。"
    exit 0
fi

# 件数の多い順に「件数<TAB>キー」を返す小さなヘルパー。
# 連想配列には順序が無いので、いったん行に展開して sort に渡す。
sort_desc() {
    local -n ref="$1"   # ${!ref[@]} で呼び出し元の連想配列を参照する(nameref)
    local key
    for key in "${!ref[@]}"; do
        printf '%s\t%s\n' "${ref[$key]}" "$key"
    done | sort -t "$(printf '\t')" -k1,1nr -k2,2
}

percent() {
    awk -v n="$1" -v total="$2" 'BEGIN { printf "%.1f", (n / total) * 100 }'
}

# ---------------------------------------------------------------------
# Markdownレポートの生成
# ---------------------------------------------------------------------
{
    printf '# アラート日次サマリ %s\n\n' "$TARGET_DATE"
    printf -- '- 生成日時: %s\n' "$(ar_now_str)"
    printf -- '- 記録件数(受け取った通知の総数): **%d 件**\n' "$TOTAL"
    printf -- '- 動作モード: %s\n\n' "$AR_MODE"
    printf '> この日に発生した通知は、即時通知したかどうかに関わらず\n'
    printf '> すべて `%s` に記録されています。通知を減らしても記録は減らしていません。\n\n' \
        "$AR_RECORD_FILE"

    printf '## 1. 重要度別の内訳\n\n'
    printf '| 重要度 | 意味 | 件数 | 割合 |\n'
    printf '|---|---|---:|---:|\n'
    printf '| P1 | 即時対応(メンション付きで即時通知) | %d | %s%% |\n' \
        "${SEVERITY_HITS[P1]:-0}" "$(percent "${SEVERITY_HITS[P1]:-0}" "$TOTAL")"
    printf '| P2 | 翌営業日対応(まとめて通知) | %d | %s%% |\n' \
        "${SEVERITY_HITS[P2]:-0}" "$(percent "${SEVERITY_HITS[P2]:-0}" "$TOTAL")"
    printf '| P3 | 記録のみ(このサマリで確認) | %d | %s%% |\n\n' \
        "${SEVERITY_HITS[P3]:-0}" "$(percent "${SEVERITY_HITS[P3]:-0}" "$TOTAL")"

    printf '## 2. 処理結果の内訳\n\n'
    printf '| 処理 | 意味 | 件数 |\n'
    printf '|---|---|---:|\n'
    printf '| notified | 即時通知した(P1) | %d |\n' "${ACTION_HITS[notified]:-0}"
    printf '| aggregated | 集約ウィンドウにまとめた(P2) | %d |\n' "${ACTION_HITS[aggregated]:-0}"
    printf '| deduped | まったく同じ文面の再送のため通知を省いた | %d |\n' "${ACTION_HITS[deduped]:-0}"
    printf '| recorded | 記録のみ(P3) | %d |\n\n' "${ACTION_HITS[recorded]:-0}"

    printf '## 3. ルール別の内訳(多い順)\n\n'
    printf '| ルールID | 重要度 | 件数 | 割合 | 内容 |\n'
    printf '|---|---|---:|---:|---|\n'
    while IFS=$'\t' read -r count rule_id; do
        [[ -z "$count" ]] && continue
        printf '| %s | %s | %d | %s%% | %s |\n' \
            "$rule_id" \
            "${AR_RULE_SEVERITY[$rule_id]:-$AR_UNMATCHED_SEVERITY}" \
            "$count" \
            "$(percent "$count" "$TOTAL")" \
            "${AR_RULE_DESC[$rule_id]:-未分類(ルール未整備)}"
    done < <(sort_desc RULE_HITS)
    printf '\n'

    printf '## 4. 記録のみ(P3)にした通知の内訳\n\n'
    printf 'ここに並んでいるのが「即時通知しなかった通知」です。\n'
    printf '毎朝ここを確認し、本当に即時通知が不要だったかを点検してください。\n'
    printf '不要でなかったものが見つかったら、`alert-rules.conf` の重要度を上げます。\n\n'
    if [[ "${#P3_HITS[@]}" -eq 0 ]]; then
        printf '(この日はP3の通知はありませんでした)\n\n'
    else
        printf '| ルールID | 件数 | 内容 |\n'
        printf '|---|---:|---|\n'
        while IFS=$'\t' read -r count rule_id; do
            [[ -z "$count" ]] && continue
            printf '| %s | %d | %s |\n' \
                "$rule_id" "$count" "${AR_RULE_DESC[$rule_id]:-未分類(ルール未整備)}"
        done < <(sort_desc P3_HITS)
        printf '\n'
    fi

    printf '## 5. 発生元別の内訳\n\n'
    printf '| 発生元 | 件数 |\n'
    printf '|---|---:|\n'
    while IFS=$'\t' read -r count source_name; do
        [[ -z "$count" ]] && continue
        printf '| %s | %d |\n' "$source_name" "$count"
    done < <(sort_desc SOURCE_HITS)
    printf '\n'

    if [[ "${#ADJUST_HITS[@]}" -gt 0 ]]; then
        printf '## 6. 重要度の補正が入った通知\n\n'
        printf '| 補正の種類 | 件数 |\n'
        printf '|---|---:|\n'
        while IFS=$'\t' read -r count adjust_name; do
            [[ -z "$count" ]] && continue
            printf '| %s | %d |\n' "$adjust_name" "$count"
        done < <(sort_desc ADJUST_HITS)
        printf '\n'
    fi

    unmatched="${RULE_HITS[UNMATCHED]:-0}"
    printf '## 7. 未分類の通知\n\n'
    if [[ "$unmatched" -gt 0 ]]; then
        printf -- '- **%d 件** の通知がどのルールにも一致しませんでした。\n' "$unmatched"
        printf -- '- これらは安全側に倒して %s として即時通知しています。\n' "$AR_UNMATCHED_SEVERITY"
        printf -- '- `alert-rules.conf` にルールを追加してください。\n\n'
    else
        printf -- '- 未分類の通知はありませんでした(ルールは現状の通知をすべてカバーしています)。\n\n'
    fi
} >"$OUT_FILE"

ar_log INFO "日次サマリを生成しました: ${OUT_FILE}"

# ---------------------------------------------------------------------
# Slackへの通知(1日1件だけ)
# ---------------------------------------------------------------------
if [[ "$DO_NOTIFY" == "true" ]]; then
    summary_text=":memo: *アラート日次サマリ ${TARGET_DATE}*
記録件数(受け取った通知の総数): ${TOTAL} 件
内訳: P1 ${SEVERITY_HITS[P1]:-0} 件 / P2 ${SEVERITY_HITS[P2]:-0} 件 / P3 ${SEVERITY_HITS[P3]:-0} 件
即時通知: ${ACTION_HITS[notified]:-0} 件 / 集約: ${ACTION_HITS[aggregated]:-0} 件 / 記録のみ: ${ACTION_HITS[recorded]:-0} 件
未分類: ${RULE_HITS[UNMATCHED]:-0} 件
詳細レポート: ${OUT_FILE}"

    ar_send_gated "daily" "$summary_text"
    ar_log INFO "日次サマリを通知しました(通知先: daily)"
fi

exit 0
