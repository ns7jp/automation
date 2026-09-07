#!/usr/bin/env bash
#
# =====================================================================
# generate_sample_logs.sh
# 改善案件No.1: 月次運用報告書の自動生成 - サンプルログ生成スクリプト
#
# 目的:
#   ops_report.sh を「手元のPC1台」で試せるようにするための、
#   検証用サンプルログを生成する。
#   本番相当のログ(案件No.2 backup.sh / 案件No.4 health_check.sh が
#   出力するログ)と同じ書式で、1か月分のログを作り出す。
#
# 生成されるもの(出力先ディレクトリを OUT とする):
#   OUT/collected/<サーバー名>/backup.log
#       … 案件No.2 backup.sh のログ書式(サーバー6台分)
#   OUT/server-health-check/history.csv
#       … 案件No.4 health_check.sh の履歴CSV(全サーバー分が1ファイル)
#   OUT/server-health-check/health_check.log
#       … 案件No.4 health_check.sh の実行ログ(障害イベント行を含む)
#
# 実行方法:
#   ./generate_sample_logs.sh                   # 前月分を ./sample-logs に生成
#   ./generate_sample_logs.sh -m 2026-08        # 対象月を指定
#   ./generate_sample_logs.sh -o /tmp/logs      # 出力先を指定
#
# 注意(正直な但し書き):
#   ここで作られるログは「検証用に人工的に作ったデータ」であり、
#   実在する企業の実運用データではない。障害の発生日時なども、
#   毎回同じレポートが再現できるよう意図的に固定している
#   (ランダムではなく決め打ち)。
# =====================================================================

set -u
# -u : 未定義の変数を参照したらエラーで止める(タイプミスの早期発見)。

# ----------------------------------------------------------------
# 既定値
# ----------------------------------------------------------------
TARGET_MONTH=""
OUT_DIR="./sample-logs"

usage() {
    cat <<'USAGE'
使い方:
  generate_sample_logs.sh [-m YYYY-MM] [-o 出力先ディレクトリ]

オプション:
  -m YYYY-MM   生成する対象月(省略時は「前月」)
  -o DIR       出力先ディレクトリ(省略時は ./sample-logs)
  -h           このヘルプを表示する
USAGE
}

while getopts ':m:o:h' opt; do
    case "$opt" in
        m) TARGET_MONTH="$OPTARG" ;;
        o) OUT_DIR="$OPTARG" ;;
        h) usage; exit 0 ;;
        :) echo "[ERROR] オプション -${OPTARG} には値が必要です" >&2; exit 1 ;;
        \?) echo "[ERROR] 不明なオプション: -${OPTARG}" >&2; usage >&2; exit 1 ;;
    esac
done

# ----------------------------------------------------------------
# 対象月の決定
# ----------------------------------------------------------------
# 「前月」を求めるとき date -d "-1 month" は月末日で事故る
#   (例: 3月31日に実行すると "2月31日" → 3月3日 と解釈されてしまう)。
# そのため「今月1日から1日引く」= 確実に前月末日、という手順を踏む。
# 詳しい理由は 03-design.md の「dateコマンドで前月を求める」を参照。
if [ -z "$TARGET_MONTH" ]; then
    first_day_this_month="$(date '+%Y-%m-01')"
    TARGET_MONTH="$(date -d "${first_day_this_month} -1 day" '+%Y-%m')"
fi

# 書式チェック(YYYY-MM 以外を弾く)
if ! printf '%s' "$TARGET_MONTH" | grep -Eq '^[0-9]{4}-(0[1-9]|1[0-2])$'; then
    echo "[ERROR] 対象月の書式が不正です: ${TARGET_MONTH}(正しくは YYYY-MM)" >&2
    exit 1
fi

# その月の日数を求める:
#   「対象月の1日 + 1か月 - 1日」= 対象月の末日 → その日付部分が日数になる
DAYS_IN_MONTH="$(date -d "${TARGET_MONTH}-01 +1 month -1 day" '+%d')"
DAYS_IN_MONTH="$((10#${DAYS_IN_MONTH}))"
# 10#... は「10進数として解釈せよ」の指定。"08" や "09" を
# 8進数と誤解釈してエラーになるのを防ぐ(bashの有名な落とし穴)。

# ----------------------------------------------------------------
# 対象サーバー(6台)の定義
# ----------------------------------------------------------------
# 案件No.4 の targets.conf に合わせた5台 + ファイルサーバー1台の計6台構成。
# 書式: 名前|監視方法|監視対象
SERVERS=(
    "web01|http|http://192.168.1.11/"
    "web02|http|https://192.168.1.12/"
    "api01|http|http://192.168.1.13:8080/healthz"
    "db01|ping|192.168.1.21"
    "app01|ping|192.168.1.22"
    "file01|ping|192.168.1.23"
)

# バックアップ先ディスク使用率の「基準値」(サーバーごと)
# file01 だけ意図的に高めにして、月後半に容量警告(80%以上)が
# 出るシナリオにしてある(レポートの「特記事項」の題材になる)。
declare -A DISK_BASE=(
    [web01]=58 [web02]=61 [api01]=45
    [db01]=72  [app01]=50 [file01]=75
)

# バックアップ対象ディレクトリ(サーバーごとに違う想定)
declare -A BACKUP_SRC=(
    [web01]=/var/www/html
    [web02]=/var/www/html
    [api01]=/opt/api/data
    [db01]=/var/lib/mysql-dump
    [app01]=/opt/app/data
    [file01]=/srv/share
)

# --- 障害シナリオ(決め打ち・毎回同じ結果になる) ---
# 1) db01: 対象月12日 03:00〜04:00 にダウン(死活監視NG)
# 2) web02: 対象月19日 14:00〜14:30 にダウン(死活監視NG)
# 3) db01: 対象月12日・25日 のバックアップが失敗(tar 終了コード2)
INCIDENT1_DAY=12
INCIDENT2_DAY=19
BACKUP_FAIL_SERVER="db01"
BACKUP_FAIL_DAYS=(12 25)

# ----------------------------------------------------------------
# 出力先の準備
# ----------------------------------------------------------------
COLLECTED_DIR="${OUT_DIR}/collected"
HEALTH_DIR="${OUT_DIR}/server-health-check"

mkdir -p "$HEALTH_DIR"

echo "[INFO] 対象月       : ${TARGET_MONTH}(${DAYS_IN_MONTH}日間)"
echo "[INFO] 出力先       : ${OUT_DIR}"
echo "[INFO] 対象サーバー : ${#SERVERS[@]}台"

# ----------------------------------------------------------------
# 1. バックアップログ(案件No.2 backup.sh 書式)の生成
# ----------------------------------------------------------------
# 1行の書式: "YYYY-MM-DD HH:MM:SS [レベル] メッセージ"
# 実物の backup.sh が出す文言をそのまま再現している。
echo "[INFO] バックアップログを生成しています..."

for entry in "${SERVERS[@]}"; do
    IFS='|' read -r name _type _target <<< "$entry"

    server_dir="${COLLECTED_DIR}/${name}"
    mkdir -p "$server_dir"
    log_path="${server_dir}/backup.log"
    : > "$log_path"   # 既存ファイルを空にしてから作り直す

    src_dir="${BACKUP_SRC[$name]}"
    base_usage="${DISK_BASE[$name]}"

    for ((day = 1; day <= DAYS_IN_MONTH; day++)); do
        date_str="$(printf '%s-%02d' "$TARGET_MONTH" "$day")"

        # この日このサーバーのバックアップは失敗するか?
        is_fail="no"
        if [ "$name" = "$BACKUP_FAIL_SERVER" ]; then
            for fail_day in "${BACKUP_FAIL_DAYS[@]}"; do
                [ "$day" -eq "$fail_day" ] && is_fail="yes"
            done
        fi

        # ディスク使用率は日が進むにつれて少しずつ増える想定
        usage=$(( base_usage + (day - 1) / 5 ))

        {
            echo "${date_str} 03:00:01 [INFO] ===== バックアップ処理を開始します ====="
            echo "${date_str} 03:00:01 [INFO] バックアップを作成します: /var/backups/html-backup/html-backup-${date_str//-/}.tar.gz"

            if [ "$is_fail" = "yes" ]; then
                echo "${date_str} 03:00:04 [ERROR] バックアップ作成に失敗しました(tar終了コード: 2)"
            else
                echo "${date_str} 03:00:0$(( (day % 5) + 3 )) [INFO] バックアップ作成に成功しました(サイズ: $(( 800 + day * 7 ))M)"
                echo "${date_str} 03:00:09 [INFO] 7日より古いバックアップを検索・削除します"
                if [ "$((day % 3))" -eq 0 ]; then
                    echo "${date_str} 03:00:09 [INFO] 古いバックアップを削除します: /var/backups/html-backup/html-backup-old.tar.gz"
                else
                    echo "${date_str} 03:00:09 [INFO] 削除対象の古いバックアップはありませんでした"
                fi
                echo "${date_str} 03:00:10 [INFO] バックアップ先の使用率: ${usage}%(警告閾値: 80%)"
                if [ "$usage" -ge 80 ]; then
                    echo "${date_str} 03:00:10 [WARN] バックアップ先の空き容量が閾値を超えています(${usage}% >= 80%)"
                fi
                echo "${date_str} 03:00:11 [INFO] ===== バックアップ処理が正常に終了しました ====="
            fi
        } >> "$log_path"
    done

    # 「対象ディレクトリ」をログの先頭コメント的に残すことはしない。
    # backup.sh の実物がそうしないため、書式を合わせている。
    echo "[INFO]   - ${name}: ${log_path}(対象: ${src_dir})"
done

# ----------------------------------------------------------------
# 2. 死活監視の履歴CSV(案件No.4 history.csv 書式)の生成
# ----------------------------------------------------------------
# 書式: timestamp,name,type,target,status
#   例: 2026-08-01 00:00:01,web01,http,http://192.168.1.11/,OK
# 5分間隔 × 24時間 = 1日288回 × サーバー6台 なので行数が多くなる。
# bashのループでは遅すぎるため、生成は awk に任せている
# (awk は「1行ずつの処理」が非常に速い)。
echo "[INFO] 死活監視の履歴CSVを生成しています..."

HISTORY_FILE="${HEALTH_DIR}/history.csv"

# サーバー定義を awk に渡すため、"名前|方法|対象" を改行区切りの文字列にする
SERVER_LIST="$(printf '%s\n' "${SERVERS[@]}")"

awk -v ym="$TARGET_MONTH" \
    -v days="$DAYS_IN_MONTH" \
    -v servers="$SERVER_LIST" \
    -v inc1_day="$INCIDENT1_DAY" \
    -v inc2_day="$INCIDENT2_DAY" '
BEGIN {
    # servers を改行で分解し、さらに "|" で 名前/方法/対象 に分ける
    n = split(servers, lines, "\n")
    for (i = 1; i <= n; i++) {
        split(lines[i], f, "|")
        name[i] = f[1]; type[i] = f[2]; target[i] = f[3]
    }

    print "timestamp,name,type,target,status"

    for (d = 1; d <= days; d++) {
        for (slot = 0; slot < 288; slot++) {      # 288 = 24時間 ÷ 5分
            hh = int(slot * 5 / 60)
            mm = (slot * 5) % 60
            ts = sprintf("%s-%02d %02d:%02d:01", ym, d, hh, mm)

            for (i = 1; i <= n; i++) {
                status = "OK"

                # 障害シナリオ1: db01 が 12日 03:00〜04:00 にダウン
                if (name[i] == "db01" && d == inc1_day && hh == 3) {
                    status = "NG"
                }
                # 障害シナリオ2: web02 が 19日 14:00〜14:30 にダウン
                if (name[i] == "web02" && d == inc2_day && hh == 14 && mm <= 30) {
                    status = "NG"
                }

                printf "%s,%s,%s,%s,%s\n", ts, name[i], type[i], target[i], status
            }
        }
    }
}' > "$HISTORY_FILE"

history_lines="$(wc -l < "$HISTORY_FILE")"
echo "[INFO]   - ${HISTORY_FILE}(${history_lines}行)"

# ----------------------------------------------------------------
# 3. 死活監視の実行ログ(案件No.4 health_check.log 書式)の生成
# ----------------------------------------------------------------
# 【正直な但し書き】
#   実運用の health_check.log には5分ごとの INFO 行が大量に入るが、
#   サンプルではファイルが巨大になるだけで学習の役に立たないため、
#   「1日1回分の通常INFO行 + 障害関連行」だけに間引いて生成している。
#   ops_report.sh が読むのは [ERROR] 行と「復旧しました」行だけなので、
#   間引いても集計結果は変わらない。
echo "[INFO] 死活監視の実行ログを生成しています..."

HEALTH_LOG="${HEALTH_DIR}/health_check.log"
: > "$HEALTH_LOG"

for ((day = 1; day <= DAYS_IN_MONTH; day++)); do
    date_str="$(printf '%s-%02d' "$TARGET_MONTH" "$day")"

    {
        echo "${date_str} 00:00:01 [INFO] ===== サーバー死活監視を開始します ====="
        for entry in "${SERVERS[@]}"; do
            IFS='|' read -r name _type target <<< "$entry"
            echo "${date_str} 00:00:02 [INFO] ${name}(${target})は正常です"
        done
        echo "${date_str} 00:00:03 [INFO] 監視完了: 対象${#SERVERS[@]}台中、NG 0台"
        echo "${date_str} 00:00:03 [INFO] ===== サーバー死活監視を終了します ====="
    } >> "$HEALTH_LOG"

    # --- 障害シナリオ1: db01(12日 03:00〜04:00) ---
    if [ "$day" -eq "$INCIDENT1_DAY" ]; then
        {
            echo "${date_str} 03:00:02 [WARN] db01(192.168.1.21)がNGです(連続1回目。通知の閾値は2回)"
            echo "${date_str} 03:05:02 [ERROR] db01(192.168.1.21)が2回連続でNGです。閾値(2回)を超えたため異常として通知します"
            echo "${date_str} 04:00:02 [INFO] db01(192.168.1.21)が復旧しました"
        } >> "$HEALTH_LOG"
    fi

    # --- 障害シナリオ2: web02(19日 14:00〜14:30) ---
    if [ "$day" -eq "$INCIDENT2_DAY" ]; then
        {
            echo "${date_str} 14:00:02 [WARN] web02(https://192.168.1.12/)がNGです(連続1回目。通知の閾値は2回)"
            echo "${date_str} 14:05:02 [ERROR] web02(https://192.168.1.12/)が2回連続でNGです。閾値(2回)を超えたため異常として通知します"
            echo "${date_str} 14:35:02 [INFO] web02(https://192.168.1.12/)が復旧しました"
        } >> "$HEALTH_LOG"
    fi
done

health_log_lines="$(wc -l < "$HEALTH_LOG")"
echo "[INFO]   - ${HEALTH_LOG}(${health_log_lines}行)"

# ----------------------------------------------------------------
# 完了メッセージ
# ----------------------------------------------------------------
cat <<EOF

[INFO] サンプルログの生成が完了しました。

次のステップ:
  1) ops_report.conf の入力パスを、生成したディレクトリに合わせる
       BACKUP_LOG_ROOT="$(cd "$COLLECTED_DIR" && pwd)"
       HEALTH_HISTORY_FILE="$(cd "$HEALTH_DIR" && pwd)/history.csv"
       HEALTH_LOG_FILE="$(cd "$HEALTH_DIR" && pwd)/health_check.log"
  2) レポートを生成する
       ./ops_report.sh ${TARGET_MONTH}
EOF
