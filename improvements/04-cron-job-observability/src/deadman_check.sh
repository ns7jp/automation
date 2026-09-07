#!/usr/bin/env bash
#
# =====================================================================
# deadman_check.sh
# 改善案件No.4: cronのサイレント障害を実行結果の可視化と失敗検知で撲滅
#   - デッドマン監視(未実行検知)スクリプト
#
# 概要:
#   「ジョブが失敗した」ことは run_job.sh が検知できるが、
#   「ジョブがそもそも起動しなかった」ことは、ジョブ自身には検知できない。
#   (起動していないのだから、通知するコードも動かない)
#
#   そこでこのスクリプトは、実行記録CSVを外側から眺めて
#   「本来なら記録があるはずの時刻を過ぎても記録が無い」ジョブを探す。
#   これがデッドマン監視(dead man's switch = 定期的な合図が
#   途絶えたことをもって異常とみなす仕組み)である。
#
#   判定式:
#     現在時刻 - 最終実行の開始時刻 > (想定実行間隔 + 猶予時間)
#       → そのジョブは「未実行(MISSING)」とみなして通知する
#
#   通知は「状態が変わったときだけ」行う。
#   未実行を検知するたびに通知すると、10分ごとに同じ通知が届き続けて
#   誰も読まなくなる(オオカミ少年状態)ためである。
#
# 使い方:
#   deadman_check.sh
#   (通常はcronから10分ごとに自動実行される。src/crontab.example 参照)
#
# 終了ステータス:
#   0  : 正常終了(未実行を検知した場合も、検知は「正常な仕事」なので0)
#   90 : 設定ファイル・台帳が見つからないなど、スクリプト自身のエラー
#
#   ※ このスクリプト自身も run_job.sh 経由で実行するため、
#     未実行の検知を「失敗」として返してしまうと、
#     ラッパーからも二重に失敗通知が飛んでしまう。それを避けている。
#
# 前提:
#   同じディレクトリに job_observability.conf が配置されていること。
#   (環境変数 JOBOBS_CONF で別のファイルを指定することもできる)
# =====================================================================

set -u

# ----------------------------------------------------------------
# 設定ファイルの読み込み
# ----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${JOBOBS_CONF:-${SCRIPT_DIR}/job_observability.conf}"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "[ERROR] 設定ファイルが見つかりません: ${CONFIG_FILE}" >&2
    exit 90
fi

# shellcheck source=job_observability.conf
source "$CONFIG_FILE"

if [ ! -f "$JOBS_FILE" ]; then
    echo "[ERROR] ジョブ台帳が見つかりません: ${JOBS_FILE}" >&2
    exit 90
fi

mkdir -p "$STATE_DIR" "$(dirname "$RUNNER_LOG")" || exit 90

HOSTNAME_SHORT="$(hostname -s 2>/dev/null || echo unknown)"
NOW_EPOCH="$(date '+%s')"
NOW_TEXT="$(date '+%Y-%m-%d %H:%M:%S')"

# ----------------------------------------------------------------
# 共通関数(run_job.sh と同じ考え方の通知処理)
# ----------------------------------------------------------------

runner_log() {
    local level="$1"
    shift
    printf '%s [%s] [deadman] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >> "$RUNNER_LOG"
}

json_escape() {
    printf '%s' "$1" \
        | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
        | awk 'BEGIN { ORS = "" } { if (NR > 1) printf "\\n"; print }'
}

notify() {
    local title="$1"
    local body="$2"
    local payload

    if [ "$ENABLE_SLACK_NOTIFY" != "true" ] || [ "$SLACK_WEBHOOK_URL" = "<YOUR_SLACK_WEBHOOK_URL>" ]; then
        runner_log "NOTIFY" "(送信せず記録のみ) ${title} | ${body}"
        return 0
    fi

    payload="{\"text\":\"$(json_escape "${title}"$'\n'"${body}")\"}"

    if curl -s -m "$CURL_TIMEOUT" -X POST \
        -H 'Content-type: application/json' \
        --data "$payload" "$SLACK_WEBHOOK_URL" > /dev/null; then
        runner_log "INFO" "Slack通知を送信しました: ${title}"
    else
        runner_log "WARN" "Slack通知の送信に失敗しました: ${title}"
    fi
}

# minutes_to_text: 分数を「◯時間◯分」の読みやすい形に変換する
#   通知本文で「1685分経過」と書かれても直感的に分からないため
minutes_to_text() {
    local minutes="$1"
    if [ "$minutes" -lt 60 ]; then
        printf '%d分' "$minutes"
    else
        printf '%d時間%d分' "$(( minutes / 60 ))" "$(( minutes % 60 ))"
    fi
}

# ----------------------------------------------------------------
# メイン処理
# ----------------------------------------------------------------
runner_log "INFO" "===== デッドマン監視を開始します ====="
echo "===== デッドマン監視 (${NOW_TEXT}) ====="

if [ ! -f "$RECORD_FILE" ]; then
    # 実行記録がまだ1件も無い状態。移行の初日はこの状態になりうる。
    echo "[WARN] 実行記録CSVがまだありません: ${RECORD_FILE}"
    runner_log "WARN" "実行記録CSVがまだありません: ${RECORD_FILE}"
fi

MISSING_COUNT=0
CHECKED_COUNT=0

# ジョブ台帳を1行ずつ読む。
#   - sed でコメント(#以降)と空行を取り除き、カンマ前後のスペースも整える
#   - 読み込みはファイル記述子3番から行う(<&3 / 3< ...)。
#     ループの中でcurlなどを呼んだときに、標準入力を横取りされて
#     ループが途中で終わってしまう事故を防ぐための定番の書き方。
while IFS=',' read -r job_id interval_min grace_min enabled description <&3; do
    [ -n "$job_id" ] || continue
    [ "$enabled" = "yes" ] || continue

    CHECKED_COUNT=$(( CHECKED_COUNT + 1 ))
    limit_min=$(( interval_min + grace_min ))
    alert_flag="${STATE_DIR}/deadman-${job_id}.alerted"

    # 実行記録CSVから、このジョブの「最後に実行された記録」を取り出す。
    # SKIPPED(多重起動で実行しなかった)は「処理が行われていない」ため、
    # 実行済みとはみなさず、SUCCESS と FAILED だけを対象にする。
    #
    # 記録CSVは「終わった順」に追記されるため、行の並び順と開始時刻の順は
    # 一致しないことがある(長時間かかったジョブは後ろに回る)。
    # そこで最終行を採るのではなく、開始時刻(1列目)が最大のものを探している。
    # ISO 8601形式の日時は「文字列として大きい = 時刻として新しい」ため、
    # 単純な文字列比較で最新の記録を選べる。
    last_started=""
    if [ -f "$RECORD_FILE" ]; then
        last_started="$(awk -F',' -v id="$job_id" \
            '$3 == id && ($4 == "SUCCESS" || $4 == "FAILED") { if ($1 > latest) latest = $1 } END { print latest }' \
            "$RECORD_FILE")"
    fi

    if [ -z "$last_started" ]; then
        # 一度も実行記録が無い = 移行直後か、最初から動いていない
        elapsed_min="-"
        state="MISSING"
        detail="実行記録が1件もありません(移行直後の場合は初回実行までお待ちください)"
    else
        last_epoch="$(date -d "$last_started" '+%s' 2>/dev/null || echo 0)"
        elapsed_min=$(( (NOW_EPOCH - last_epoch) / 60 ))
        if [ "$elapsed_min" -gt "$limit_min" ]; then
            state="MISSING"
            detail="最終実行 ${last_started} から $(minutes_to_text "$elapsed_min") 経過(許容 $(minutes_to_text "$limit_min"))"
        else
            state="OK"
            detail="最終実行 ${last_started}($(minutes_to_text "$elapsed_min")前)"
        fi
    fi

    if [ "$state" = "MISSING" ]; then
        MISSING_COUNT=$(( MISSING_COUNT + 1 ))
        echo "[MISSING] ${job_id} : ${detail}"

        if [ -f "$alert_flag" ]; then
            # すでに通知済み。同じ内容を繰り返し送らない(通知の抑止)
            runner_log "INFO" "未実行を検知(通知済みのため再通知しません): ${job_id}"
        else
            runner_log "WARN" "未実行を検知しました: ${job_id} / ${detail}"
            notify ":alarm_clock: cronジョブが実行されていません (${job_id})" \
                "$(printf 'ホスト: %s\n検知時刻: %s\n説明: %s\n%s\n想定実行間隔: %s分 / 猶予: %s分\ncrontabの設定・cronサービスの状態・サーバーの時刻を確認してください。' \
                    "$HOSTNAME_SHORT" "$NOW_TEXT" "$description" "$detail" "$interval_min" "$grace_min")"
            touch "$alert_flag"
        fi
    else
        echo "[OK]      ${job_id} : ${detail}"

        if [ -f "$alert_flag" ]; then
            # 未実行だったジョブの記録が再び現れた = 復旧
            runner_log "INFO" "未実行から復旧しました: ${job_id}"
            notify ":white_check_mark: cronジョブの実行を確認しました (${job_id})" \
                "$(printf 'ホスト: %s\n復旧確認時刻: %s\n%s' "$HOSTNAME_SHORT" "$NOW_TEXT" "$detail")"
            rm -f "$alert_flag"
        fi
    fi
done 3< <(sed -e 's/#.*$//' \
              -e 's/^[[:space:]]*//' \
              -e 's/[[:space:]]*$//' \
              -e 's/[[:space:]]*,[[:space:]]*/,/g' \
              -e '/^$/d' "$JOBS_FILE")

echo "----- 判定結果: 対象 ${CHECKED_COUNT} 件 / 未実行 ${MISSING_COUNT} 件 -----"
runner_log "INFO" "===== デッドマン監視を終了します(対象${CHECKED_COUNT}件/未実行${MISSING_COUNT}件)====="

exit 0
