#!/usr/bin/env bash
# =====================================================================
# shadow-compare.sh
# 改善案件No.3: アラート過多の改善 - 新旧の判定結果を突き合わせる
#
# ■ 何をするスクリプトか
#   影実行(shadow)期間に集めたデータを使って、
#     ・従来どおりなら何件通知していたか(旧)
#     ・新しい分類ルールなら何件通知することになるか(新)
#   を並べて比較し、削減率を出す。あわせて
#     ・P3(記録のみ)に落とした通知の一覧
#     ・どのルールにも一致しなかった通知の件数
#   を出力する。
#
# ■ なぜ必要か
#   通知を減らす改善でいちばん怖いのは、「重要な通知まで消してしまう」こと。
#   いきなり本番の通知を絞ると、消したことに気づけないまま障害を見逃す。
#   そこで、まず「判定だけを新方式で行い、通知は従来どおり全件流す」
#   という影実行を一定期間動かし、このスクリプトで結果を突き合わせる。
#   「P3に落とす予定の通知の中に、本当は重要なものが無いか」を
#   人間の目で確認してから、はじめて本稼働へ切り替える。
#
# ■ 使い方
#   ./shadow-compare.sh --date 2026-09-01
#   ./shadow-compare.sh --date 2026-09-01 --list-p3      # P3の全件を表示
#   ./shadow-compare.sh --date 2026-09-01 --format md > compare.md
#
# ■ 注意
#   送信台帳(outbox.log)は日付で絞り込まずに全件を数える。
#   測定のたびに outbox.log を空にしてから流し込むこと
#   (手順は 04-build-guide.md のStep 9を参照)。
#
# ■ 依存コマンド: bash 4.0以降, jq, awk, sort, uniq
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
FORMAT="text"
LIST_P3="false"
RECORDS_FILE="$AR_RECORD_FILE"
OUTBOX_FILE="$AR_OUTBOX"

usage() {
    cat <<'USAGE'
使い方: shadow-compare.sh --date <YYYY-MM-DD> [オプション]

オプション:
  --date <YYYY-MM-DD>  比較対象日(省略時は昨日)
  --records <ファイル> 記録ファイル(既定は設定の AR_RECORD_FILE)
  --outbox <ファイル>  送信台帳(既定は設定の AR_OUTBOX)
  --list-p3            P3(記録のみ)にした通知を全件表示する
  --format <text|md>   出力形式(既定 text)
  -h, --help           このヘルプを表示する
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --date)    TARGET_DATE="${2:-}"; shift 2 ;;
        --records) RECORDS_FILE="${2:-}"; shift 2 ;;
        --outbox)  OUTBOX_FILE="${2:-}"; shift 2 ;;
        --list-p3) LIST_P3="true"; shift ;;
        --format)  FORMAT="${2:-text}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) printf '[ERROR] 不明なオプションです: %s\n' "$1" >&2; usage >&2; exit 1 ;;
    esac
done

ar_require_command jq awk sort uniq || exit 1

if [[ -z "$TARGET_DATE" ]]; then
    TARGET_DATE="$(date -d 'yesterday' '+%Y-%m-%d')"
fi
if [[ ! -f "$RECORDS_FILE" ]]; then
    printf '[ERROR] 記録ファイルが見つかりません: %s\n' "$RECORDS_FILE" >&2
    exit 1
fi

AR_QUIET="true"
if ! ar_load_rules "$AR_RULES_FILE"; then
    exit 1
fi

# ---------------------------------------------------------------------
# 記録ファイルから対象日の集計を取る
# ---------------------------------------------------------------------
declare -A SEVERITY_HITS=()
declare -A ACTION_HITS=()
declare -A P3_HITS=()
TOTAL=0

records_tsv="$(jq -r --arg d "$TARGET_DATE" \
    'select(.date == $d) | [.severity, .action, .rule_id] | @tsv' "$RECORDS_FILE")"

if [[ -n "$records_tsv" ]]; then
    while IFS=$'\t' read -r severity action rule_id; do
        [[ -z "$severity" ]] && continue
        SEVERITY_HITS["$severity"]=$(( ${SEVERITY_HITS["$severity"]:-0} + 1 ))
        ACTION_HITS["$action"]=$(( ${ACTION_HITS["$action"]:-0} + 1 ))
        [[ "$severity" == "P3" ]] && P3_HITS["$rule_id"]=$(( ${P3_HITS["$rule_id"]:-0} + 1 ))
        TOTAL=$((TOTAL + 1))
    done <<<"$records_tsv"
fi

if [[ "$TOTAL" -eq 0 ]]; then
    printf '[ERROR] %s の記録が1件もありません: %s\n' "$TARGET_DATE" "$RECORDS_FILE" >&2
    exit 1
fi

# ---------------------------------------------------------------------
# 送信台帳から「旧経路」「新経路」の実通知件数を数える
#   台帳の書式: 日時<TAB>通知先<TAB>状態<TAB>本文
#   legacy               … 影実行で従来どおり流している旧チャンネルへの通知
#   critical / daily     … 新方式で送る(送る予定の)通知
# ---------------------------------------------------------------------
count_channel() {
    local channel="$1"
    if [[ ! -f "$OUTBOX_FILE" ]]; then
        printf '0'
        return 0
    fi
    awk -F'\t' -v ch="$channel" '$2 == ch { c++ } END { print c + 0 }' "$OUTBOX_FILE"
}

legacy_count="$(count_channel legacy)"
critical_count="$(count_channel critical)"
daily_count="$(count_channel daily)"
new_count=$(( critical_count + daily_count ))

# 旧経路の件数が取れない場合(本稼働後など)は、記録の総件数を旧件数とみなす。
# 影実行では「受け取った通知=旧方式で通知していた件数」がそのまま成り立つため。
if [[ "$legacy_count" -eq 0 ]]; then
    legacy_count="$TOTAL"
fi

reduction="$(awk -v old="$legacy_count" -v new="$new_count" \
    'BEGIN { if (old == 0) { print "0.0" } else { printf "%.1f", (1 - new / old) * 100 } }')"

percent() {
    awk -v n="$1" -v total="$2" 'BEGIN { printf "%.1f", (n / total) * 100 }'
}

sort_desc_p3() {
    local key
    for key in "${!P3_HITS[@]}"; do
        printf '%s\t%s\n' "${P3_HITS[$key]}" "$key"
    done | sort -t "$(printf '\t')" -k1,1nr -k2,2
}

# ---------------------------------------------------------------------
# 出力
# ---------------------------------------------------------------------
if [[ "$FORMAT" == "md" ]]; then
    printf '## 影実行の突き合わせ結果(%s)\n\n' "$TARGET_DATE"
    printf '| 項目 | 件数 |\n|---|---:|\n'
    printf '| 受け取った通知(=記録件数) | %d |\n' "$TOTAL"
    printf '| 旧方式で通知していた件数 | %d |\n' "$legacy_count"
    printf '| 新方式で通知する件数(P1即時) | %d |\n' "$critical_count"
    printf '| 新方式で通知する件数(P2まとめ・日次サマリ) | %d |\n' "$daily_count"
    printf '| **新方式の通知合計** | **%d** |\n' "$new_count"
    printf '| **削減率** | **%s%%** |\n\n' "$reduction"

    printf '### 重要度別の判定結果\n\n'
    printf '| 重要度 | 件数 | 割合 |\n|---|---:|---:|\n'
    for severity in P1 P2 P3; do
        printf '| %s | %d | %s%% |\n' \
            "$severity" "${SEVERITY_HITS[$severity]:-0}" \
            "$(percent "${SEVERITY_HITS[$severity]:-0}" "$TOTAL")"
    done
    printf '\n'

    printf '### P3(記録のみ)に落とした通知\n\n'
    printf '**この表が、この改善で「即時通知しないことにした通知」のすべてです。**\n'
    printf '本当に即時通知が不要かどうか、1行ずつ目で確認してください。\n\n'
    printf '| ルールID | 件数 | 内容 |\n|---|---:|---|\n'
    while IFS=$'\t' read -r count rule_id; do
        [[ -z "$count" ]] && continue
        printf '| %s | %d | %s |\n' "$rule_id" "$count" "${AR_RULE_DESC[$rule_id]:-未分類}"
    done < <(sort_desc_p3)
    printf '\n'
else
    printf '\n===== 影実行の突き合わせ結果(%s)=====\n\n' "$TARGET_DATE"
    printf '受け取った通知(=記録件数)          : %6d 件\n' "$TOTAL"
    printf '旧方式で通知していた件数            : %6d 件\n' "$legacy_count"
    printf '新方式で通知する件数(P1即時)      : %6d 件\n' "$critical_count"
    printf '新方式で通知する件数(P2・サマリ)  : %6d 件\n' "$daily_count"
    printf -- '------------------------------------------------\n'
    printf '新方式の通知合計                    : %6d 件\n' "$new_count"
    printf '削減率                              : %6s %%\n\n' "$reduction"

    printf '%s\n' '----- 重要度別の判定結果 -----'
    for severity in P1 P2 P3; do
        printf '%-4s %6d 件 (%5s%%)\n' \
            "$severity" "${SEVERITY_HITS[$severity]:-0}" \
            "$(percent "${SEVERITY_HITS[$severity]:-0}" "$TOTAL")"
    done
    printf '\n'

    printf '%s\n' '----- 処理結果の内訳 -----'
    printf 'notified  (即時通知)      : %6d 件\n' "${ACTION_HITS[notified]:-0}"
    printf 'aggregated(集約)          : %6d 件\n' "${ACTION_HITS[aggregated]:-0}"
    printf 'deduped   (重複排除)      : %6d 件\n' "${ACTION_HITS[deduped]:-0}"
    printf 'recorded  (記録のみ)      : %6d 件\n\n' "${ACTION_HITS[recorded]:-0}"

    printf '%s\n' '----- P3(記録のみ)に落とした通知 -----'
    printf '※本当に即時通知が不要か、1行ずつ確認すること\n'
    while IFS=$'\t' read -r count rule_id; do
        [[ -z "$count" ]] && continue
        printf '%-9s %6d 件  %s\n' "$rule_id" "$count" "${AR_RULE_DESC[$rule_id]:-未分類}"
    done < <(sort_desc_p3)
    printf '\n'
fi

# 未分類は必ず目立たせる
unmatched=0
if [[ -n "$records_tsv" ]]; then
    unmatched="$(printf '%s\n' "$records_tsv" | awk -F'\t' '$3 == "UNMATCHED" { c++ } END { print c + 0 }')"
fi
if [[ "$unmatched" -gt 0 ]]; then
    printf '[注意] どのルールにも一致しない通知が %s 件あります(安全側で %s 扱い)。\n' \
        "$unmatched" "$AR_UNMATCHED_SEVERITY" >&2
    printf '       本稼働へ切り替える前に alert-rules.conf を整備してください。\n' >&2
fi

# --list-p3: P3にした通知の本文を全件表示する(目視レビュー用)
if [[ "$LIST_P3" == "true" ]]; then
    printf '\n===== P3(記録のみ)にした通知の全件 =====\n'
    jq -r --arg d "$TARGET_DATE" \
        'select(.date == $d and .severity == "P3") | [.ts, .rule_id, .host, .message] | @tsv' \
        "$RECORDS_FILE" |
        while IFS=$'\t' read -r ts rule_id host message; do
            printf '%s  %-6s %-9s %s\n' "$ts" "$rule_id" "$host" "$message"
        done
    printf '\n'
fi

exit 0
