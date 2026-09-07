#!/usr/bin/env bash
# =====================================================================
# alert-inventory.sh
# 改善案件No.3: アラート過多の改善 - 通知の棚卸し(集計)スクリプト
#
# ■ 何をするスクリプトか
#   通知ログを読み込み、「どの種類の通知が何件出ているか」を
#   種類別に集計して表にする。
#
# ■ なぜ最初にこれをやるのか
#   改善の第一歩は「減らすこと」ではなく「数えること」。
#   感覚で「通知が多すぎる」と言っても、どこから手を付ければよいか
#   分からないし、改善後に「本当に減ったのか」も示せない。
#   まず種類別に数えれば、
#     ・上位3種類だけで全体の何割を占めるのか
#     ・どの種類を減らせば一番効くのか
#     ・そもそも対応が必要な通知はどれくらいあるのか
#   が数字で分かる。これが改善案件でいちばん大事な作業になる。
#
# ■ 使い方
#   ./alert-inventory.sh --input sample-alerts.tsv
#   ./alert-inventory.sh --input sample-alerts.tsv --days 14
#   ./alert-inventory.sh --input sample-alerts.tsv --format md > inventory.md
#
# ■ 入力形式(タブ区切り)
#   発生日時<TAB>発生元<TAB>ホスト名<TAB>通知本文
#
# ■ 依存コマンド: bash 4.0以降, sort, awk
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

INPUT_FILE=""
FORMAT="text"
DAYS=1

usage() {
    cat <<'USAGE'
使い方: alert-inventory.sh --input <通知ログ> [オプション]

オプション:
  --input <ファイル>  集計対象の通知ログ(タブ区切り)。必須
  --days <N>          ログが何日分かを指定する(既定 1)。1日平均の算出に使う
  --format <text|md>  出力形式(既定 text)。md はMarkdownの表で出力する
  -h, --help          このヘルプを表示する
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --input)  INPUT_FILE="${2:-}"; shift 2 ;;
        --days)   DAYS="${2:-1}"; shift 2 ;;
        --format) FORMAT="${2:-text}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) printf '[ERROR] 不明なオプションです: %s\n' "$1" >&2; usage >&2; exit 1 ;;
    esac
done

if [[ -z "$INPUT_FILE" || ! -f "$INPUT_FILE" ]]; then
    printf '[ERROR] --input で集計対象の通知ログを指定してください。\n' >&2
    usage >&2
    exit 1
fi
if ! [[ "$DAYS" =~ ^[1-9][0-9]*$ ]]; then
    printf '[ERROR] --days は1以上の整数で指定してください: %s\n' "$DAYS" >&2
    exit 1
fi

# 棚卸しでは通知を送らないので、静かに動かす
# common.sh の ar_log がこの値を見る(export しておくと共通関数側から確実に参照できる)
export AR_QUIET="true"
if ! ar_load_rules "$AR_RULES_FILE"; then
    exit 1
fi

# ---------------------------------------------------------------------
# 集計用の連想配列
#   RULE_HITS[ルールID]     … そのルールに一致した件数
#   SEVERITY_HITS[重要度]   … P1/P2/P3ごとの件数
#   SOURCE_HITS[発生元]     … 発生元ごとの件数
# 連想配列を使うと「キーが出てくるたびに1ずつ足す」という集計が
# 数行で書ける。事前にキーの一覧を用意しておく必要もない。
# ---------------------------------------------------------------------
declare -A RULE_HITS=()
declare -A SEVERITY_HITS=()
declare -A SOURCE_HITS=()
TOTAL=0

while IFS=$'\t' read -r ts src host message; do
    [[ -z "${ts// /}" ]] && continue
    [[ "$ts" == \#* ]] && continue

    classified="$(ar_classify "$(ar_sanitize "${message:-}")")"
    IFS=$'\t' read -r rule_id severity channel window <<<"$classified"

    RULE_HITS["$rule_id"]=$(( ${RULE_HITS["$rule_id"]:-0} + 1 ))
    SEVERITY_HITS["$severity"]=$(( ${SEVERITY_HITS["$severity"]:-0} + 1 ))
    SOURCE_HITS["${src:-unknown}"]=$(( ${SOURCE_HITS["${src:-unknown}"]:-0} + 1 ))
    TOTAL=$((TOTAL + 1))
done <"$INPUT_FILE"

# ホスト名は集計に使っていないが、入力形式の説明として変数名を残している。
# shellcheck disable=SC2034
: "${host:-}" "${channel:-}" "${window:-}"

if [[ "$TOTAL" -eq 0 ]]; then
    printf '[ERROR] 集計対象の行が1件もありませんでした: %s\n' "$INPUT_FILE" >&2
    exit 1
fi

# ---------------------------------------------------------------------
# 表示用の共通計算
#   割合は小数第1位まで出したいので awk で計算する
#   (Bashの算術式は整数しか扱えないため)
# ---------------------------------------------------------------------
percent() {
    awk -v n="$1" -v total="$2" 'BEGIN { printf "%.1f", (n / total) * 100 }'
}
per_day() {
    awk -v n="$1" -v days="$2" 'BEGIN { printf "%.1f", n / days }'
}

# 件数の多い順に並べ替えたルールIDの一覧を作る。
# 連想配列そのものには順序が無いので、いったん「件数<TAB>ID」の
# 行に展開してから sort に渡す(定石のやり方)。
sorted_rules="$(
    for rule_id in "${!RULE_HITS[@]}"; do
        printf '%s\t%s\n' "${RULE_HITS[$rule_id]}" "$rule_id"
    done | sort -t "$(printf '\t')" -k1,1nr -k2,2
)"

# ---------------------------------------------------------------------
# 出力
# ---------------------------------------------------------------------
if [[ "$FORMAT" == "md" ]]; then
    printf '## 通知の棚卸し結果\n\n'
    printf -- '- 集計対象: `%s`\n' "$INPUT_FILE"
    printf -- '- 集計期間: %d日分 / 合計 %d 件(1日あたり %s 件)\n\n' \
        "$DAYS" "$TOTAL" "$(per_day "$TOTAL" "$DAYS")"
    printf '| ルールID | 重要度 | 通知先 | 件数 | 1日あたり | 割合 | 内容 |\n'
    printf '|---|---|---|---:|---:|---:|---|\n'
    while IFS=$'\t' read -r count rule_id; do
        [[ -z "$count" ]] && continue
        printf '| %s | %s | %s | %s | %s | %s%% | %s |\n' \
            "$rule_id" \
            "${AR_RULE_SEVERITY[$rule_id]:-$AR_UNMATCHED_SEVERITY}" \
            "${AR_RULE_CHANNEL[$rule_id]:-critical}" \
            "$count" \
            "$(per_day "$count" "$DAYS")" \
            "$(percent "$count" "$TOTAL")" \
            "${AR_RULE_DESC[$rule_id]:-未分類(どのルールにも一致しなかった)}"
    done <<<"$sorted_rules"
    printf '| **合計** | | | **%s** | **%s** | **100.0%%** | |\n\n' \
        "$TOTAL" "$(per_day "$TOTAL" "$DAYS")"

    printf '### 重要度別の内訳\n\n'
    printf '| 重要度 | 件数 | 1日あたり | 割合 |\n'
    printf '|---|---:|---:|---:|\n'
    for severity in P1 P2 P3; do
        count="${SEVERITY_HITS[$severity]:-0}"
        printf '| %s | %s | %s | %s%% |\n' \
            "$severity" "$count" "$(per_day "$count" "$DAYS")" "$(percent "$count" "$TOTAL")"
    done
    printf '\n'
else
    printf '\n===== 通知の棚卸し結果 =====\n'
    printf '集計対象: %s\n' "$INPUT_FILE"
    printf '集計期間: %d日分 / 合計 %d 件(1日あたり %s 件)\n\n' \
        "$DAYS" "$TOTAL" "$(per_day "$TOTAL" "$DAYS")"
    # 見出しは半角英字にしている。日本語は1文字が3バイトになるため、
    # printf の桁揃え(%-9s など)は文字数ではなくバイト数で数えられ、
    # 日本語の見出しを使うと表がずれてしまうため。
    # (RULE=ルールID / SEV=重要度 / CHANNEL=通知先 / COUNT=件数
    #  / PER-DAY=1日あたり / SHARE=割合)
    printf '%-9s %-4s %-9s %7s %9s %7s  %s\n' \
        "RULE" "SEV" "CHANNEL" "COUNT" "PER-DAY" "SHARE" "内容"
    printf -- '-------------------------------------------------------------------------------------\n'
    while IFS=$'\t' read -r count rule_id; do
        [[ -z "$count" ]] && continue
        printf '%-9s %-4s %-9s %7s %9s %6s%%  %s\n' \
            "$rule_id" \
            "${AR_RULE_SEVERITY[$rule_id]:-$AR_UNMATCHED_SEVERITY}" \
            "${AR_RULE_CHANNEL[$rule_id]:-critical}" \
            "$count" \
            "$(per_day "$count" "$DAYS")" \
            "$(percent "$count" "$TOTAL")" \
            "${AR_RULE_DESC[$rule_id]:-未分類(どのルールにも一致しなかった)}"
    done <<<"$sorted_rules"
    printf -- '-------------------------------------------------------------------------------------\n'
    printf '%-9s %-4s %-9s %7s %9s %6s%%\n\n' \
        "TOTAL" "" "" "$TOTAL" "$(per_day "$TOTAL" "$DAYS")" "100.0"

    printf '%s\n' '----- 重要度別の内訳 -----'
    for severity in P1 P2 P3; do
        count="${SEVERITY_HITS[$severity]:-0}"
        printf '%-4s %7s 件  1日あたり %6s 件  (%5s%%)\n' \
            "$severity" "$count" "$(per_day "$count" "$DAYS")" "$(percent "$count" "$TOTAL")"
    done
    printf '\n'

    printf '%s\n' '----- 発生元別の内訳 -----'
    for src_name in "${!SOURCE_HITS[@]}"; do
        printf '%s\t%s\n' "${SOURCE_HITS[$src_name]}" "$src_name"
    done | sort -t "$(printf '\t')" -k1,1nr | while IFS=$'\t' read -r count src_name; do
        printf '%-14s %7s 件  (%5s%%)\n' "$src_name" "$count" "$(percent "$count" "$TOTAL")"
    done
    printf '\n'
fi

# 未分類が残っているときは、ルール整備が足りていないという警告を出す
unmatched="${RULE_HITS[UNMATCHED]:-0}"
if [[ "$unmatched" -gt 0 ]]; then
    printf '[注意] どのルールにも一致しない通知が %s 件あります。\n' "$unmatched" >&2
    printf '       これらは安全側に倒して %s として扱われます。\n' "$AR_UNMATCHED_SEVERITY" >&2
    printf '       alert-rules.conf にルールを追加してください。\n' >&2
fi

exit 0
