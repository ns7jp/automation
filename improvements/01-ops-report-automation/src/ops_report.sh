#!/usr/bin/env bash
#
# =====================================================================
# ops_report.sh
# 改善案件No.1: 月次運用報告書の作成を自動集計・自動生成に改善
#                                                   - 本体スクリプト
#
# 概要:
#   1. 対象月(既定は「前月」)の日付範囲を date コマンドで算出する。
#   2. 案件No.2(バックアップ自動化)が出力した backup.log から
#      サーバーごとのバックアップ成功/失敗件数とディスク使用率を集計する。
#   3. 案件No.4(サーバー死活監視)が出力した history.csv から
#      サーバーごとの死活監視回数・OK/NG件数・稼働率を集計する。
#   4. 同じく health_check.log から障害イベント(検知→復旧)を抽出し、
#      継続時間を計算して一覧にする。
#   5. 以上をヒアドキュメントで組み立て、Markdown形式の
#      月次運用報告書を生成する(必要ならHTML版も生成する)。
#   6. 生成完了をSlackへ通知する。
#
# 実行方法:
#   ./ops_report.sh              # 前月分のレポートを生成する
#   ./ops_report.sh 2026-08      # 対象月を指定して生成する
#   ./ops_report.sh -n 2026-08   # ドライラン(標準出力に出すだけ・保存しない)
#
# 前提:
#   同じディレクトリに ops_report.conf が配置されていること。
#   (環境変数 OPS_REPORT_CONF で別の設定ファイルを指定することもできる)
#
# 設計方針:
#   案件No.2 / No.4 と同じく、あえて `set -e` は付けていない。
#   一部のログが欠けていても「読めたぶんだけ集計してレポートを出す」
#   ほうが運用上ありがたいため、各コマンドの結果は自前で判定する。
# =====================================================================

set -u
# -u : 未定義の変数を参照したらエラーで止める(タイプミスの早期発見)。

# ----------------------------------------------------------------
# 設定ファイルの読み込み
# ----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${OPS_REPORT_CONF:-${SCRIPT_DIR}/ops_report.conf}"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "[ERROR] 設定ファイルが見つかりません: ${CONFIG_FILE}" >&2
    exit 1
fi

# shellcheck source=ops_report.conf
source "$CONFIG_FILE"

# ----------------------------------------------------------------
# 引数の解析
# ----------------------------------------------------------------
DRY_RUN="no"

while getopts ':nh' opt; do
    case "$opt" in
        n) DRY_RUN="yes" ;;
        h)
            cat <<'USAGE'
使い方:
  ops_report.sh [-n] [YYYY-MM]

引数:
  YYYY-MM   レポート対象月(省略時は「前月」)

オプション:
  -n        ドライラン。ファイルに保存せず標準出力に表示するだけ。
            Slack通知も行わない(移行期間の突き合わせ確認に使う)。
  -h        このヘルプを表示する。
USAGE
            exit 0
            ;;
        \?) echo "[ERROR] 不明なオプション: -${OPTARG}" >&2; exit 1 ;;
        :)  echo "[ERROR] オプション -${OPTARG} には値が必要です" >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

TARGET_MONTH="${1:-}"

# ----------------------------------------------------------------
# 共通関数
# ----------------------------------------------------------------

# log: 日時・ログレベル付きでログファイルと標準エラー出力の両方に出力する
#   引数1: ログレベル(INFO / WARN / ERROR)
#   引数2以降: メッセージ本文
#
#   ※ レポート本文を標準出力に出す(ドライラン)ケースがあるため、
#      進捗ログは標準エラー出力(>&2)側に流している。
#      こうしておくと `ops_report.sh -n > out.md` としたときに
#      ログがレポート本文に混ざらない。
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    if [ -n "${LOG_FILE:-}" ]; then
        echo "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE" >&2
    else
        echo "${timestamp} [${level}] ${message}" >&2
    fi
}

# notify_slack: Slack Incoming Webhookへ通知メッセージを送信する
#   curl自体が失敗してもスクリプト全体を止めないよう、戻り値は判定しない
#   (案件No.2 / No.4 と同じ方針)。
notify_slack() {
    local message="$1"

    if [ "${ENABLE_SLACK_NOTIFY}" != "true" ]; then
        return 0
    fi
    if [ "${SLACK_WEBHOOK_URL}" = "<YOUR_SLACK_WEBHOOK_URL>" ] || [ -z "${SLACK_WEBHOOK_URL}" ]; then
        log "WARN" "SLACK_WEBHOOK_URL が未設定のため、Slack通知をスキップしました"
        return 0
    fi

    curl -s -X POST -H 'Content-type: application/json' \
        --data "{\"text\": \"${message}\"}" \
        "${SLACK_WEBHOOK_URL}" > /dev/null
}

# pct: 割り算をして「パーセント」を小数第2位まで求める
#   bashは小数の計算ができないため、計算は awk に任せる。
#   引数1: 分子 / 引数2: 分母
#   分母が0のときは "N/A" を返す(0除算でスクリプトを止めないため)。
pct() {
    awk -v a="$1" -v b="$2" 'BEGIN {
        if (b + 0 == 0) { print "N/A" } else { printf "%.2f", (a / b) * 100 }
    }'
}

# judge: 実績値が目標値以上かどうかを判定し、記号付きの文字列を返す
#   引数1: 実績値 / 引数2: 目標値
judge() {
    awk -v actual="$1" -v target="$2" 'BEGIN {
        if (actual == "N/A") { print "- 判定不可" }
        else if (actual + 0 >= target + 0) { print "✅ 達成" }
        else { print "⚠️ 未達" }
    }'
}

# ----------------------------------------------------------------
# 1. 対象月と日付範囲の算出
# ----------------------------------------------------------------
#
# 【なぜ date -d "-1 month" を使わないのか】
#   3月31日に `date -d "-1 month"` を実行すると "2月31日" という
#   存在しない日付になり、GNU dateはこれを3月3日に繰り上げてしまう。
#   つまり「3月31日の前月」が3月になるという事故が起きる。
#   そこで
#     (a) 今月の1日を求める           → 2026-09-01
#     (b) そこから1日引く             → 2026-08-31(必ず前月末日)
#     (c) その月の1日を求める         → 2026-08-01(前月初日)
#   という、月末日に依存しない手順を踏んでいる。
#
if [ -z "$TARGET_MONTH" ]; then
    first_day_this_month="$(date '+%Y-%m-01')"
    TARGET_MONTH="$(date -d "${first_day_this_month} -1 day" '+%Y-%m')"
fi

if ! printf '%s' "$TARGET_MONTH" | grep -Eq '^[0-9]{4}-(0[1-9]|1[0-2])$'; then
    echo "[ERROR] 対象月の書式が不正です: ${TARGET_MONTH}(正しくは YYYY-MM)" >&2
    exit 1
fi

START_DATE="${TARGET_MONTH}-01"                                        # 例: 2026-08-01
END_DATE="$(date -d "${START_DATE} +1 month -1 day" '+%Y-%m-%d')"      # 例: 2026-08-31
NEXT_MONTH_FIRST="$(date -d "${START_DATE} +1 month" '+%Y-%m-%d')"     # 例: 2026-09-01
DAYS_IN_MONTH="$(date -d "$END_DATE" '+%d')"
DAYS_IN_MONTH="$((10#${DAYS_IN_MONTH}))"   # "08" を8進数と誤解釈させないための 10# 指定

# history.csv の1列目は "YYYY-MM-DD HH:MM:SS" 形式。
# この形式は年→月→日→時→分→秒の順に桁が並ぶため、
# 文字列としてそのまま大小比較しても時系列の前後関係と一致する
# (辞書順の比較 = 時系列の比較になる。案件No.4と同じ考え方)。
START_TS="${START_DATE} 00:00:00"
END_TS_EXCL="${NEXT_MONTH_FIRST} 00:00:00"

# 日本語表記(レポートの見出し用)
YEAR="${TARGET_MONTH%-*}"
MONTH_NUM="$((10#${TARGET_MONTH#*-}))"

# ----------------------------------------------------------------
# 2. 出力先の準備
# ----------------------------------------------------------------
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
mkdir -p "$REPORT_DIR" 2>/dev/null || true

REPORT_FILE="${REPORT_DIR}/ops-report-${TARGET_MONTH}.md"
GENERATED_AT="$(date '+%Y-%m-%d %H:%M:%S')"

log "INFO" "===== 月次運用報告書の生成を開始します(対象月: ${TARGET_MONTH}) ====="
log "INFO" "集計期間: ${START_DATE} 〜 ${END_DATE}(${DAYS_IN_MONTH}日間)"

# ドライランのときは、実ファイルではなく一時ファイルに書き出す
if [ "$DRY_RUN" = "yes" ]; then
    REPORT_FILE="$(mktemp)"
    log "INFO" "ドライランモード: ファイルには保存せず標準出力へ表示します"
fi

# ----------------------------------------------------------------
# 3. バックアップログの集計
# ----------------------------------------------------------------
#
# 【awkでの集計の考え方】
#   backup.log の1行はこうなっている:
#     2026-08-01 03:00:10 [INFO] バックアップ先の使用率: 72%(警告閾値: 80%)
#     ~~~~~~~~~~ ~~~~~~~~ ~~~~~~
#        $1        $2       $3      ← awk は空白で区切って $1,$2,... と番号を振る
#   つまり $1 が日付。「$1 が対象月の範囲内なら数える」だけで
#   月次の絞り込みができる。日付が YYYY-MM-DD 形式で桁が揃っているため、
#   文字列比較のままで大小関係が正しく判定できる。
#
BACKUP_SERVERS=()
declare -A BK_OK BK_NG BK_MAXDISK

if [ -d "$BACKUP_LOG_ROOT" ]; then
    # サーバー名(サブディレクトリ名)をアルファベット順に並べて処理する
    while IFS= read -r server_dir; do
        server_name="$(basename "$server_dir")"
        backup_log="${server_dir}/${BACKUP_LOG_NAME}"

        if [ ! -f "$backup_log" ]; then
            log "WARN" "${server_name}: バックアップログが見つかりません(${backup_log})。集計から除外します"
            continue
        fi

        # awk 1回の実行で「成功件数」「失敗件数」「ディスク使用率の最大値」を
        # まとめて数える。ログを3回読み直すより速く、処理の意図もまとまる。
        read -r ok_count ng_count max_disk <<< "$(
            awk -v s="$START_DATE" -v e="$END_DATE" '
                # $1(日付)が対象月の範囲内の行だけを処理対象にする
                $1 >= s && $1 <= e {
                    # index(文字列, 探す文字列) は「見つかった位置」を返す。
                    # 0 より大きければ「その文言が含まれている」という意味。
                    if (index($0, "バックアップ作成に成功しました") > 0) ok++
                    if (index($0, "バックアップ作成に失敗しました") > 0) ng++

                    # 「使用率: 72%」の部分だけを取り出して数値にする
                    if (match($0, /使用率: [0-9]+%/)) {
                        v = substr($0, RSTART, RLENGTH)   # → "使用率: 72%"
                        gsub(/[^0-9]/, "", v)             # → "72"(数字以外を削除)
                        if (v + 0 > maxd) maxd = v + 0    # 月内の最大値を覚えておく
                    }
                }
                # END は「全行を読み終わったあと」に1回だけ実行されるブロック
                END { printf "%d %d %d\n", ok + 0, ng + 0, maxd + 0 }
            ' "$backup_log"
        )"

        BACKUP_SERVERS+=("$server_name")
        BK_OK["$server_name"]="$ok_count"
        BK_NG["$server_name"]="$ng_count"
        BK_MAXDISK["$server_name"]="$max_disk"

        log "INFO" "${server_name}: バックアップ 成功${ok_count}件 / 失敗${ng_count}件 / ディスク最大${max_disk}%"
    done < <(find "$BACKUP_LOG_ROOT" -mindepth 1 -maxdepth 1 -type d | sort)
else
    log "WARN" "バックアップログの親ディレクトリが存在しません: ${BACKUP_LOG_ROOT}"
fi

# 全サーバー合計
TOTAL_BK_OK=0
TOTAL_BK_NG=0
for s in ${BACKUP_SERVERS[@]+"${BACKUP_SERVERS[@]}"}; do
    TOTAL_BK_OK=$((TOTAL_BK_OK + BK_OK[$s]))
    TOTAL_BK_NG=$((TOTAL_BK_NG + BK_NG[$s]))
done
TOTAL_BK_RUN=$((TOTAL_BK_OK + TOTAL_BK_NG))
BACKUP_SUCCESS_RATE="$(pct "$TOTAL_BK_OK" "$TOTAL_BK_RUN")"
SERVER_COUNT="${#BACKUP_SERVERS[@]}"

# ----------------------------------------------------------------
# 4. 死活監視の履歴CSV(history.csv)の集計
# ----------------------------------------------------------------
#
# 【awkでの集計の考え方(CSV編)】
#   -F',' で「カンマ区切り」を指定すると、
#     2026-08-01 00:00:01,web01,http,http://192.168.1.11/,OK
#     $1=タイムスタンプ  $2=サーバー名  $3=監視方法  $4=対象  $5=結果
#   のように列が取り出せる。
#   あとは「連想配列 total[$2]++」で "サーバー名ごとのカウンター" を作れば、
#   1回ログを読むだけで全サーバー分の集計が同時に終わる。
#
HEALTH_SUMMARY=""
if [ -f "$HEALTH_HISTORY_FILE" ]; then
    HEALTH_SUMMARY="$(
        awk -F',' -v s="$START_TS" -v e="$END_TS_EXCL" '
            NR == 1 { next }                 # 1行目(ヘッダー行)は読み飛ばす
            $1 >= s && $1 < e {              # 対象月の範囲内だけを集計する
                if (!($2 in seen)) {         # 初めて出てきたサーバー名を順番に記録
                    seen[$2] = 1
                    order[++n] = $2
                    type[$2] = $3
                }
                total[$2]++                  # サーバーごとのチェック回数
                if ($5 == "OK") ok[$2]++     # そのうち成功した回数
            }
            END {
                for (i = 1; i <= n; i++) {
                    name = order[i]
                    t = total[name]
                    o = ok[name] + 0
                    printf "%s,%s,%d,%d,%d,%.2f\n", name, type[name], t, o, t - o, (o / t) * 100
                }
            }
        ' "$HEALTH_HISTORY_FILE"
    )"
else
    log "WARN" "死活監視の履歴CSVが見つかりません: ${HEALTH_HISTORY_FILE}"
fi

# 全サーバー合計から平均稼働率を求める
TOTAL_HC_CHECK=0
TOTAL_HC_OK=0
if [ -n "$HEALTH_SUMMARY" ]; then
    while IFS=',' read -r _name _type h_total h_ok _h_ng _h_rate; do
        [ -z "$_name" ] && continue
        TOTAL_HC_CHECK=$((TOTAL_HC_CHECK + h_total))
        TOTAL_HC_OK=$((TOTAL_HC_OK + h_ok))
    done <<< "$HEALTH_SUMMARY"
fi
AVG_UPTIME="$(pct "$TOTAL_HC_OK" "$TOTAL_HC_CHECK")"

log "INFO" "死活監視: 総チェック ${TOTAL_HC_CHECK}回 / OK ${TOTAL_HC_OK}回 / 平均稼働率 ${AVG_UPTIME}%"

# ----------------------------------------------------------------
# 5. 障害イベントの抽出(検知 → 復旧 のペアにする)
# ----------------------------------------------------------------
#
# health_check.log から必要な2種類の行だけを取り出す。
#   検知: 2026-08-12 03:05:02 [ERROR] db01(192.168.1.21)が2回連続でNGです。…
#   復旧: 2026-08-12 04:00:02 [INFO]  db01(192.168.1.21)が復旧しました
# awk 側では「時刻」「種別」「残りの文言」をタブ区切りで出力し、
# サーバー名の切り出しは bash 側で行う(そのほうが読みやすいため)。
#
INCIDENT_ROWS=()      # レポートの表に出す1行分の文字列
INCIDENT_SERVERS=()   # サーバー別の件数集計(sort | uniq -c)に使う
declare -A OPEN_AT    # 「検知したがまだ復旧していない」障害の検知時刻

if [ -f "$HEALTH_LOG_FILE" ]; then
    while IFS=$'\t' read -r ev_time ev_kind ev_rest; do
        [ -z "$ev_time" ] && continue

        # "db01(192.168.1.21)が2回連続で…" から "db01" だけを取り出す。
        # ${変数%%パターン} は「後ろ側から最長一致した部分を削る」記法。
        # ここでは「最初の ( 以降をすべて削る」ことで名前だけを残している。
        ev_server="${ev_rest%%(*}"

        if [ "$ev_kind" = "DETECT" ]; then
            # すでに未復旧の障害が記録されていれば、二重に数えない
            if [ -z "${OPEN_AT[$ev_server]:-}" ]; then
                OPEN_AT["$ev_server"]="$ev_time"
                INCIDENT_SERVERS+=("$ev_server")
            fi
        else
            detect_time="${OPEN_AT[$ev_server]:-}"
            if [ -n "$detect_time" ]; then
                # date -d "日時" +%s で「1970年1月1日からの経過秒数」に変換できる。
                # 秒数同士なら単純な引き算で経過時間が求められる。
                start_epoch="$(date -d "$detect_time" '+%s')"
                end_epoch="$(date -d "$ev_time" '+%s')"
                duration_min=$(( (end_epoch - start_epoch) / 60 ))

                INCIDENT_ROWS+=("| ${detect_time} | ${ev_server} | 死活監視NGが連続で発生(自動検知) | ${ev_time} | 約${duration_min}分 |")
                unset "OPEN_AT[$ev_server]"
            fi
        fi
    done < <(
        awk -v s="$START_DATE" -v e="$END_DATE" '
            $1 >= s && $1 <= e {
                if ($3 == "[ERROR]" && index($0, "連続でNGです") > 0) {
                    printf "%s %s\tDETECT\t%s\n", $1, $2, $4
                } else if ($3 == "[INFO]" && index($0, "復旧しました") > 0) {
                    printf "%s %s\tRECOVER\t%s\n", $1, $2, $4
                }
            }
        ' "$HEALTH_LOG_FILE"
    )

    # 月末時点でまだ復旧していない障害があれば、復旧欄を「未復旧」として出す
    for still_down in ${!OPEN_AT[@]+"${!OPEN_AT[@]}"}; do
        INCIDENT_ROWS+=("| ${OPEN_AT[$still_down]} | ${still_down} | 死活監視NGが連続で発生(自動検知) | (月内に復旧確認なし) | - |")
    done
else
    log "WARN" "死活監視の実行ログが見つかりません: ${HEALTH_LOG_FILE}"
fi

INCIDENT_COUNT="${#INCIDENT_ROWS[@]}"
log "INFO" "障害イベント: ${INCIDENT_COUNT}件を抽出しました"

# --- サーバー別の障害件数を sort | uniq -c で数える ---
#   sort      : 同じサーバー名を隣り合わせに並べる
#   uniq -c   : 隣り合う同じ行をまとめ、件数を先頭に付ける
#   sort -rn  : 件数の多い順(逆順・数値順)に並べ替える
#   ※ uniq は「隣り合う行」しか比較しないため、必ず先に sort が要る。
INCIDENT_RANK=""
if [ "${#INCIDENT_SERVERS[@]}" -gt 0 ]; then
    INCIDENT_RANK="$(printf '%s\n' "${INCIDENT_SERVERS[@]}" | sort | uniq -c | sort -rn)"
fi

# ----------------------------------------------------------------
# 6. Markdownレポートの組み立て(ヒアドキュメント)
# ----------------------------------------------------------------
#
# 【ヒアドキュメントとは】
#   cat > ファイル <<EOF ... EOF と書くと、EOF から EOF までの
#   複数行をそのままファイルに書き出せる仕組み。
#   echo を何行も並べるより、完成形のレイアウトが目で見て分かる。
#   ・<<EOF  … ${変数} が展開される(値を埋め込みたいとき)
#   ・<<'EOF'… 何も展開されない(記号をそのまま出したいとき)
#   ここでは値を埋め込むので、引用符なしの <<EOF を使う。
#
BACKUP_JUDGE="$(judge "$BACKUP_SUCCESS_RATE" "$BACKUP_SUCCESS_TARGET")"
UPTIME_JUDGE="$(judge "$AVG_UPTIME" "$UPTIME_TARGET")"
EXPECTED_BK_RUN=$((DAYS_IN_MONTH * BACKUP_EXPECTED_PER_DAY * SERVER_COUNT))

cat > "$REPORT_FILE" <<EOF
# ${YEAR}年${MONTH_NUM}月 月次運用報告書

| 項目 | 内容 |
|---|---|
| 対象組織 | ${COMPANY_NAME}(架空の依頼元) |
| 対象期間 | ${START_DATE} 〜 ${END_DATE}(${DAYS_IN_MONTH}日間) |
| 対象サーバー | ${SERVER_COUNT}台 |
| 作成者 | ${REPORT_AUTHOR} |
| 生成日時 | ${GENERATED_AT} |
| 生成方法 | \`ops_report.sh\` による自動集計・自動生成 |

> このレポートの数値はすべてログから自動集計したものであり、人手による転記は行っていない。
> 人間が編集するのは末尾の「特記事項・所感」欄のみ。

---

## 1. サマリ

| 指標 | 実績 | 目標 | 判定 |
|---|---|---|---|
| バックアップ成功率 | ${BACKUP_SUCCESS_RATE}%(成功 ${TOTAL_BK_OK} / 実行 ${TOTAL_BK_RUN}) | ${BACKUP_SUCCESS_TARGET}% | ${BACKUP_JUDGE} |
| 死活監視 平均稼働率 | ${AVG_UPTIME}%(OK ${TOTAL_HC_OK} / チェック ${TOTAL_HC_CHECK}) | ${UPTIME_TARGET}% | ${UPTIME_JUDGE} |
| 障害検知件数 | ${INCIDENT_COUNT}件 | - | - |
| バックアップ実行回数 | ${TOTAL_BK_RUN}回 | ${EXPECTED_BK_RUN}回(${SERVER_COUNT}台 × ${DAYS_IN_MONTH}日) | - |

---

## 2. バックアップ実施状況

対象: 案件No.2「定期バックアップ自動化」が各サーバーで出力した \`backup.log\`

| サーバー | 成功 | 失敗 | 実行回数 | 成功率 | ディスク使用率(月内最大) |
|---|---|---|---|---|---|
EOF

for s in ${BACKUP_SERVERS[@]+"${BACKUP_SERVERS[@]}"}; do
    ok="${BK_OK[$s]}"
    ng="${BK_NG[$s]}"
    run=$((ok + ng))
    rate="$(pct "$ok" "$run")"
    disk="${BK_MAXDISK[$s]}"

    # ディスク使用率が閾値以上なら警告マークを付ける
    if [ "$disk" -ge "$DISK_USAGE_THRESHOLD" ]; then
        disk_cell="**${disk}% ⚠ 閾値${DISK_USAGE_THRESHOLD}%超過**"
    else
        disk_cell="${disk}%"
    fi

    echo "| ${s} | ${ok}件 | ${ng}件 | ${run}回 | ${rate}% | ${disk_cell} |" >> "$REPORT_FILE"
done

cat >> "$REPORT_FILE" <<EOF
| **合計** | **${TOTAL_BK_OK}件** | **${TOTAL_BK_NG}件** | **${TOTAL_BK_RUN}回** | **${BACKUP_SUCCESS_RATE}%** | - |

---

## 3. 死活監視 稼働状況

対象: 案件No.4「サーバー死活監視」が出力した \`history.csv\`(5分間隔のチェック履歴)

| サーバー | 監視方法 | チェック回数 | OK | NG | 稼働率 | 目標(${UPTIME_TARGET}%)判定 |
|---|---|---|---|---|---|---|
EOF

if [ -n "$HEALTH_SUMMARY" ]; then
    while IFS=',' read -r h_name h_type h_total h_ok h_ng h_rate; do
        [ -z "$h_name" ] && continue
        echo "| ${h_name} | ${h_type} | ${h_total}回 | ${h_ok}回 | ${h_ng}回 | ${h_rate}% | $(judge "$h_rate" "$UPTIME_TARGET") |" >> "$REPORT_FILE"
    done <<< "$HEALTH_SUMMARY"
else
    echo "| (データなし) | - | - | - | - | - | - |" >> "$REPORT_FILE"
fi

cat >> "$REPORT_FILE" <<EOF

---

## 4. 障害イベント一覧

対象: 案件No.4 \`health_check.log\` の \`[ERROR]\`(連続NG検知)行と「復旧しました」行

| 検知日時 | サーバー | 事象 | 復旧日時 | 継続時間 |
|---|---|---|---|---|
EOF

if [ "$INCIDENT_COUNT" -gt 0 ]; then
    printf '%s\n' "${INCIDENT_ROWS[@]}" | sort >> "$REPORT_FILE"
else
    echo "| - | - | 対象期間内に検知された障害はありません | - | - |" >> "$REPORT_FILE"
fi

cat >> "$REPORT_FILE" <<'EOF'

> 「検知日時」は、連続NG回数がしきい値に達してSlack通知を送った時刻。
> 実際の停止開始は、その直前のNG(最大5分前)まで遡る可能性がある。
EOF

cat >> "$REPORT_FILE" <<EOF

---

## 5. サーバー別 障害検知件数

\`\`\`text
件数 サーバー名
EOF

if [ -n "$INCIDENT_RANK" ]; then
    echo "$INCIDENT_RANK" >> "$REPORT_FILE"
else
    echo "   0 (障害検知なし)" >> "$REPORT_FILE"
fi

cat >> "$REPORT_FILE" <<'EOF'
```
EOF

cat >> "$REPORT_FILE" <<EOF

---

## 6. 特記事項・所感

<!-- ここだけは人間が記入する欄。自動生成では上書きされる点に注意
     (追記したい場合は生成後のファイルを編集し、別名で保存すること) -->

- (自動生成時点では空欄。目視確認した担当者が3分程度で追記する)

---

## 付録: 集計条件

| 項目 | 値 |
|---|---|
| 集計期間 | ${START_TS} 〜 ${END_DATE} 23:59:59 |
| バックアップログ | \`${BACKUP_LOG_ROOT}/<サーバー名>/${BACKUP_LOG_NAME}\` |
| 死活監視履歴 | \`${HEALTH_HISTORY_FILE}\` |
| 死活監視ログ | \`${HEALTH_LOG_FILE}\` |
| 稼働率の定義 | (statusがOKのチェック回数 ÷ 全チェック回数) × 100 |
| バックアップ成功率の定義 | (「作成に成功しました」の行数 ÷ 成功+失敗の行数) × 100 |
| 生成ツール | \`ops_report.sh\`(改善案件No.1) |

※ 本レポートは学習用ポートフォリオの検証環境で生成したものであり、実在企業の運用実績ではない。
EOF

# ----------------------------------------------------------------
# 7. 出力(ドライラン / 通常)
# ----------------------------------------------------------------
if [ "$DRY_RUN" = "yes" ]; then
    cat "$REPORT_FILE"
    rm -f "$REPORT_FILE"
    log "INFO" "===== ドライランを終了しました(ファイルは保存していません) ====="
    exit 0
fi

log "INFO" "Markdownレポートを生成しました: ${REPORT_FILE}"

# ----------------------------------------------------------------
# 8. HTML版の生成(任意)
# ----------------------------------------------------------------
HTML_FILE=""
if [ "${ENABLE_HTML_REPORT}" = "true" ]; then
    HTML_FILE="${REPORT_FILE%.md}.html"
    if [ -x "${SCRIPT_DIR}/md2html.sh" ]; then
        if "${SCRIPT_DIR}/md2html.sh" "$REPORT_FILE" "$HTML_FILE"; then
            log "INFO" "HTML版レポートを生成しました: ${HTML_FILE}"
        else
            log "WARN" "HTML版の生成に失敗しました。Markdown版のみ利用してください"
            HTML_FILE=""
        fi
    else
        log "WARN" "md2html.sh が見つからない(または実行権限がない)ためHTML版を生成しませんでした"
        HTML_FILE=""
    fi
fi

# ----------------------------------------------------------------
# 9. Slack通知
# ----------------------------------------------------------------
SLACK_MESSAGE=":memo: [月次運用報告書] ${YEAR}年${MONTH_NUM}月分を自動生成しました\\n"
SLACK_MESSAGE+="・ファイル: ${REPORT_FILE}\\n"
SLACK_MESSAGE+="・バックアップ成功率: ${BACKUP_SUCCESS_RATE}%(失敗 ${TOTAL_BK_NG}件)\\n"
SLACK_MESSAGE+="・平均稼働率: ${AVG_UPTIME}%\\n"
SLACK_MESSAGE+="・障害検知: ${INCIDENT_COUNT}件\\n"
SLACK_MESSAGE+="内容を目視確認のうえ、特記事項欄の記入をお願いします。"

notify_slack "$SLACK_MESSAGE"

log "INFO" "===== 月次運用報告書の生成が正常に終了しました ====="
exit 0
