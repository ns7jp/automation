#!/usr/bin/env bash
#
# =====================================================================
# detect_drift.sh
# 改善案件No.6: サーバー台帳の自動収集・差分検知 - 差分検知スクリプト
#
# 概要:
#   1. スナップショット置き場から「最新の日付」と「その1つ前の日付」を選ぶ。
#   2. サーバーごとに、2つのJSONを「key=value の一覧」に平坦化する。
#   3. 無視設定に一致する行(毎回変わる値)を取り除く。
#   4. diff で比較し、追加・削除・変更を判定する。
#   5. Markdownの差分レポートとCSVの変更履歴を出力し、必要ならSlackへ通知する。
#
# なぜ「平坦化してから diff」なのか:
#   JSON同士をそのまま見比べても、人間には「どの項目がどう変わったか」が
#   分かりにくい。いったん
#       packages[nginx]=1.24.0-2ubuntu7
#       sudoers[deploy]=yes
#   のような1行1項目の形に直してから diff を取ると、
#   「どのキーが」「何から何に」変わったかがそのまま読める形で得られる。
#
# 使い方:
#   ./detect_drift.sh                        # 最新 vs 1つ前 を比較
#   ./detect_drift.sh --previous 2026-09-01  # 比較元の日付を明示する
#   ./detect_drift.sh --config ./test.conf
#   ./detect_drift.sh --help
#
# 終了コード:
#   0 : 差分なし(または初回収集)
#   1 : 設定不備などのエラー
#   3 : 差分を検知した(cronのログや他ツールから判定に使える)
# =====================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/inventory.conf"
CURRENT_DATE=""
PREVIOUS_DATE=""

usage() {
    cat <<'USAGE'
使い方: detect_drift.sh [オプション]

  --config <ファイル>    設定ファイルのパス(既定: 同じ場所の inventory.conf)
  --current <YYYY-MM-DD> 比較先(新しい方)の日付。既定は最新のスナップショット
  --previous <YYYY-MM-DD>比較元(古い方)の日付。既定は最新の1つ前
  --help                 このヘルプを表示する
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --config)   CONFIG_FILE="${2:-}"; shift 2 || true ;;
        --current)  CURRENT_DATE="${2:-}"; shift 2 || true ;;
        --previous) PREVIOUS_DATE="${2:-}"; shift 2 || true ;;
        --help|-h)  usage; exit 0 ;;
        *)
            echo "[ERROR] 不明なオプション: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [ ! -f "$CONFIG_FILE" ]; then
    echo "[ERROR] 設定ファイルが見つかりません: ${CONFIG_FILE}" >&2
    exit 1
fi
# shellcheck source=inventory.conf
source "$CONFIG_FILE"

if ! command -v jq >/dev/null 2>&1; then
    echo "[ERROR] jq が見つかりません。'sudo apt install jq' でインストールしてください" >&2
    exit 1
fi

mkdir -p "$REPORT_DIR" "$(dirname "$LOG_FILE")" || {
    echo "[ERROR] 出力先ディレクトリを作成できません(権限を確認してください)" >&2
    exit 1
}

log() {
    local level="$1"
    shift
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" \
        | tee -a "$LOG_FILE"
}

# ---------------------------------------------------------------
# 比較する2つの日付を決める
# ---------------------------------------------------------------
if [ ! -d "$SNAPSHOT_ROOT" ]; then
    echo "[ERROR] スナップショット置き場がありません: ${SNAPSHOT_ROOT}" >&2
    exit 1
fi

# 日付ディレクトリ名(YYYY-MM-DD)は辞書順に並べると時系列順になる。
# ISO 8601形式の日付を使う大きな利点のひとつ。
mapfile -t snapshot_dates < <(
    find "$SNAPSHOT_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
)

if [ "${#snapshot_dates[@]}" -eq 0 ]; then
    echo "[ERROR] スナップショットが1つもありません。先に collect_inventory.sh を実行してください" >&2
    exit 1
fi

if [ -z "$CURRENT_DATE" ]; then
    CURRENT_DATE="${snapshot_dates[-1]}"
fi
if [ -z "$PREVIOUS_DATE" ]; then
    # 「CURRENT_DATE より古いもののうち、いちばん新しいもの」を選ぶ。
    for d in "${snapshot_dates[@]}"; do
        if [[ "$d" < "$CURRENT_DATE" ]]; then
            PREVIOUS_DATE="$d"
        fi
    done
fi

CURRENT_DIR="${SNAPSHOT_ROOT}/${CURRENT_DATE}"
PREVIOUS_DIR="${SNAPSHOT_ROOT}/${PREVIOUS_DATE}"
REPORT_FILE="${REPORT_DIR}/drift-${CURRENT_DATE}.md"
HISTORY_CSV="${REPORT_DIR}/drift-history.csv"

log "INFO" "===== 差分検知を開始します (${PREVIOUS_DATE:-なし} -> ${CURRENT_DATE}) ====="

# ---------------------------------------------------------------
# JSONを「key=value」の一覧に平坦化する jq プログラム
#
# 例(抜粋):
#   kernel=6.8.0-45-generic
#   packages[nginx]=1.24.0-2ubuntu7
#   ports[80]=listen
#   sudoers[deploy]=yes
#   users[deploy].shell=/bin/bash
#
# リスト項目は「[要素名]」を鍵に含めることで、並び順が変わっても
# 同じ項目同士が対応づくようにしている(順序の違いを差分と誤検知しない工夫)。
# ---------------------------------------------------------------
FLATTEN_JQ=$(cat <<'JQ_PROGRAM'
def kv($k; $v): "\($k)=\($v)";

[ kv("os.name";       .facts.os.name),
  kv("os.id";         .facts.os.id),
  kv("os.version_id"; .facts.os.version_id),
  kv("kernel";        .facts.kernel),
  kv("arch";          .facts.arch),
  kv("hostname";      .facts.hostname)
]
+ (.facts.ip_addresses | map(kv("ip_addresses[\(.)]"; "assigned")))
+ (.facts.disks   | map(kv("disks[\(.mount)].size_kb";      .size_kb),
                        kv("disks[\(.mount)].used_percent"; .used_percent)))
+ (.facts.packages| map(kv("packages[\(.name)]"; .version)))
+ (.facts.services| map(kv("services[\(.)]"; "running")))
+ (.facts.users   | map(kv("users[\(.name)].uid";   .uid),
                        kv("users[\(.name)].shell"; .shell)))
+ (.facts.sudoers | map(kv("sudoers[\(.)]"; "yes")))
+ (.facts.ports   | map(kv("ports[\(.)]"; "listen")))
| sort
| .[]
JQ_PROGRAM
)

# flatten_snapshot: JSONファイルを「key=value」の並びに変換し、
#                   無視パターンに一致する行を取り除く
flatten_snapshot() {
    local json_file="$1"
    # grep -E -v : 指定した拡張正規表現に「一致しない」行だけを残す
    jq -r "$FLATTEN_JQ" "$json_file" | grep -E -v "$DRIFT_IGNORE_PATTERN"
}

# diff_facts: 平坦化した2ファイルを比較し、TSVで差分を返す
#   出力: key <TAB> 変更種別(changed/added/removed) <TAB> 変更前 <TAB> 変更後
#
# diff の "<" 行は「変更前(左のファイル)にしかない行」、
#        ">" 行は「変更後(右のファイル)にしかない行」。
# awk で key ごとに突き合わせ、両方にあれば「変更」、
# 片方だけなら「追加」「削除」と判定している。
diff_facts() {
    local old_file="$1"
    local new_file="$2"

    diff "$old_file" "$new_file" \
        | grep -E '^[<>] ' \
        | awk '
            {
                mark = substr($0, 1, 1)
                line = substr($0, 3)
                idx  = index(line, "=")
                if (idx == 0) { next }
                key = substr(line, 1, idx - 1)
                val = substr(line, idx + 1)
                if (mark == "<") { old[key] = val; seen[key] = 1 }
                else             { new[key] = val; seen[key] = 1 }
            }
            END {
                for (k in seen) {
                    o = (k in old) ? old[k] : "-"
                    n = (k in new) ? new[k] : "-"
                    if ((k in old) && (k in new)) { t = "changed" }
                    else if (k in new)            { t = "added" }
                    else                          { t = "removed" }
                    printf "%s\t%s\t%s\t%s\n", k, t, o, n
                }
            }' \
        | sort
}

# notify_slack: Slack Incoming Webhook へ通知する
#   curl 自体が失敗してもスクリプト全体は止めない(通知は補助機能のため)。
notify_slack() {
    local message="$1"

    if [ "${ENABLE_SLACK_NOTIFY}" != "true" ]; then
        log "INFO" "Slack通知は無効(ENABLE_SLACK_NOTIFY=false)のため送信しません"
        return 0
    fi

    # jq -Rs . で、改行や引用符を含む文字列を安全にJSON文字列へ変換する。
    # 自前で "\"" を組み立てると、メッセージに " が入った瞬間に壊れる。
    local payload
    payload="$(jq -n --arg text "$message" '{text: $text}')"

    if curl -sS -X POST -H 'Content-type: application/json' \
        --data "$payload" "$SLACK_WEBHOOK_URL" >/dev/null 2>&1; then
        log "INFO" "Slackへ通知しました"
    else
        log "WARN" "Slackへの通知に失敗しました(URL・ネットワークを確認してください)"
    fi
}

# ---------------------------------------------------------------
# レポートの冒頭を書き出す
# ---------------------------------------------------------------
{
    echo "# 構成ドリフト検知レポート ${CURRENT_DATE}"
    echo
    echo "| 項目 | 内容 |"
    echo "|---|---|"
    echo "| 対象組織 | ${COMPANY_NAME}(架空の依頼元) |"
    echo "| 比較元スナップショット | ${PREVIOUS_DATE:-なし(初回)} |"
    echo "| 比較先スナップショット | ${CURRENT_DATE} |"
    echo "| 生成日時 | $(date '+%Y-%m-%d %H:%M:%S') |"
    echo
} > "$REPORT_FILE"

# 変更履歴CSVが無ければヘッダーを作る(あとから表計算ソフトで開ける形式)
if [ ! -f "$HISTORY_CSV" ]; then
    echo "detected_date,host,key,change_type,before,after,severity" > "$HISTORY_CSV"
fi

# ---------------------------------------------------------------
# ホストごとに比較する
# ---------------------------------------------------------------
total_drift=0
critical_drift=0
error_hosts=0
new_hosts=0
missing_hosts=0
summary_lines=""
detail_body=""

# 一時ディレクトリ(平坦化した中間ファイルの置き場)。
# trap で終了時に必ず消すことで、ゴミが残らないようにする。
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mapfile -t current_hosts < <(
    find "$CURRENT_DIR" -maxdepth 1 -name '*.json' -printf '%f\n' 2>/dev/null \
        | sed 's/\.json$//' | sort
)

for host in "${current_hosts[@]}"; do
    cur_json="${CURRENT_DIR}/${host}.json"
    prev_json="${PREVIOUS_DIR}/${host}.json"

    # (1) 収集自体に失敗しているホスト
    cur_status="$(jq -r '.status' "$cur_json")"
    if [ "$cur_status" != "ok" ]; then
        error_hosts=$((error_hosts + 1))
        summary_lines+="| ${host} | 収集失敗 | - | - |"$'\n'
        detail_body+="### ${host}"$'\n\n'
        detail_body+="収集に失敗しているため比較できません。SSH接続と対象サーバーの状態を確認してください。"$'\n\n'
        log "ERROR" "[${host}] 収集失敗のスナップショットのため比較をスキップします"
        continue
    fi

    # (2) 前回のスナップショットが無いホスト(新規追加 or 初回実行)
    if [ -z "$PREVIOUS_DATE" ] || [ ! -f "$prev_json" ]; then
        new_hosts=$((new_hosts + 1))
        summary_lines+="| ${host} | 新規(基準作成) | - | - |"$'\n'
        detail_body+="### ${host}"$'\n\n'
        detail_body+="今回が初回収集のため、このスナップショットを比較の基準とします。"$'\n\n'
        log "INFO" "[${host}] 前回スナップショットなし。基準として登録しました"
        continue
    fi

    # (3) 通常の比較
    flatten_snapshot "$prev_json" > "${TMP_DIR}/${host}.prev"
    flatten_snapshot "$cur_json"  > "${TMP_DIR}/${host}.cur"
    diff_facts "${TMP_DIR}/${host}.prev" "${TMP_DIR}/${host}.cur" > "${TMP_DIR}/${host}.diff"

    diff_count="$(wc -l < "${TMP_DIR}/${host}.diff")"
    diff_count="${diff_count// /}"

    if [ "$diff_count" -eq 0 ]; then
        summary_lines+="| ${host} | 差分なし | 0 | 0 |"$'\n'
        log "INFO" "[${host}] 差分なし"
        continue
    fi

    host_critical=0
    host_table=""
    while IFS=$'\t' read -r key change_type before after; do
        # 重要度の判定: セキュリティに直結するキー(ユーザー・sudo権限・
        # 開放ポート・パッケージ)は「高」として強調する。
        if echo "$key" | grep -E -q "$DRIFT_CRITICAL_PATTERN"; then
            severity="高"
            host_critical=$((host_critical + 1))
        else
            severity="中"
        fi

        case "$change_type" in
            added)   change_ja="追加" ;;
            removed) change_ja="削除" ;;
            *)       change_ja="変更" ;;
        esac

        host_table+="| \`${key}\` | ${change_ja} | ${before} | ${after} | ${severity} |"$'\n'

        # 変更履歴CSVに1行ずつ追記する。
        # これが「いつ・どのサーバーの・何が変わったか」の追跡可能な記録になる。
        printf '%s,%s,%s,%s,%s,%s,%s\n' \
            "$CURRENT_DATE" "$host" "$key" "$change_ja" "$before" "$after" "$severity" \
            >> "$HISTORY_CSV"
    done < "${TMP_DIR}/${host}.diff"

    total_drift=$((total_drift + diff_count))
    critical_drift=$((critical_drift + host_critical))

    summary_lines+="| ${host} | 差分あり | ${diff_count} | ${host_critical} |"$'\n'
    detail_body+="### ${host}"$'\n\n'
    detail_body+="| 項目 | 変更種別 | 変更前 | 変更後 | 重要度 |"$'\n'
    detail_body+="|---|---|---|---|---|"$'\n'
    detail_body+="${host_table}"$'\n'

    log "WARN" "[${host}] 差分 ${diff_count} 件(うち重要 ${host_critical} 件)を検知しました"
done

# (4) 前回はあったが今回は無いホスト(収集対象から外れた/ファイルが消えた)
if [ -n "$PREVIOUS_DATE" ] && [ -d "$PREVIOUS_DIR" ]; then
    mapfile -t previous_hosts < <(
        find "$PREVIOUS_DIR" -maxdepth 1 -name '*.json' -printf '%f\n' 2>/dev/null \
            | sed 's/\.json$//' | sort
    )
    for host in "${previous_hosts[@]}"; do
        if [ ! -f "${CURRENT_DIR}/${host}.json" ]; then
            missing_hosts=$((missing_hosts + 1))
            summary_lines+="| ${host} | 今回収集なし | - | - |"$'\n'
            log "WARN" "[${host}] 前回は存在しましたが、今回のスナップショットにありません"
        fi
    done
fi

# ---------------------------------------------------------------
# レポートを組み立てる
# ---------------------------------------------------------------
{
    echo "## サマリ"
    echo
    echo "- 検知した差分: **${total_drift} 件**(うち重要度「高」: ${critical_drift} 件)"
    echo "- 収集失敗: ${error_hosts} 台 / 新規登録: ${new_hosts} 台 / 今回収集なし: ${missing_hosts} 台"
    echo
    echo "| サーバー | 判定 | 差分件数 | うち重要 |"
    echo "|---|---|---|---|"
    if [ -n "$summary_lines" ]; then
        printf '%s' "$summary_lines"
    else
        echo "| - | 対象なし | 0 | 0 |"
    fi
    echo
    echo "## 詳細"
    echo
    if [ -n "$detail_body" ]; then
        printf '%s' "$detail_body"
    else
        echo "検知された差分はありません。"
        echo
    fi
    echo "---"
    echo
    echo "本レポートは detect_drift.sh により自動生成されました。"
    echo "「重要度: 高」の差分は、意図した変更かどうかを必ず確認してください。"
} >> "$REPORT_FILE"

log "INFO" "差分レポートを出力しました: ${REPORT_FILE}"

# ---------------------------------------------------------------
# 通知
# ---------------------------------------------------------------
if [ "$total_drift" -gt 0 ] || [ "$error_hosts" -gt 0 ]; then
    notify_slack "$(printf '【構成ドリフト検知】%s\n比較: %s -> %s\n差分 %s 件(重要 %s 件) / 収集失敗 %s 台\n詳細: %s' \
        "$COMPANY_NAME" "${PREVIOUS_DATE:-なし}" "$CURRENT_DATE" \
        "$total_drift" "$critical_drift" "$error_hosts" "$REPORT_FILE")"
elif [ "${NOTIFY_ON_NO_DRIFT}" = "true" ]; then
    notify_slack "$(printf '【構成ドリフト検知】%s\n%s 時点で差分はありません(正常)' \
        "$COMPANY_NAME" "$CURRENT_DATE")"
fi

log "INFO" "===== 差分検知終了: 差分 ${total_drift} 件 / 重要 ${critical_drift} 件 ====="

if [ "$total_drift" -gt 0 ]; then
    exit 3
fi
exit 0
