#!/usr/bin/env bash
#
# =====================================================================
# run_job.sh
# 改善案件No.4: cronのサイレント障害を実行結果の可視化と失敗検知で撲滅
#   - cronジョブ共通ラッパースクリプト
#
# 概要:
#   cronから直接ジョブを起動する代わりに、このスクリプト経由で起動する。
#   ジョブ本体には一切手を入れずに、次の4つを追加できる。
#
#     1. 多重起動の防止   : flock で「同じジョブIDは同時に1つだけ」に制限する
#     2. 実行記録の保存   : 開始/終了/終了ステータス/所要時間をCSVに1行追記する
#     3. 出力の保存       : ジョブの標準出力・標準エラー出力をジョブ別ログに残す
#     4. 失敗時の即時通知 : 終了ステータスが0以外ならSlackへ通知する
#
#   「ジョブを書き換えずに、外側から観測できるようにする」のが狙い。
#   これによりバックアップ・死活監視など既存のスクリプトを
#   1行も修正せずに可視化・失敗検知の対象にできる。
#
# 使い方:
#   run_job.sh <ジョブID> <実行するコマンド> [引数...]
#
#   例) run_job.sh backup-daily /opt/backup-automation/backup.sh
#       run_job.sh health-check /opt/server-health-check/health_check.sh
#
#   パイプやリダイレクトを含むコマンドを渡したい場合は、
#   シェルに解釈させるため bash -c で包む。
#       run_job.sh db-dump bash -c 'mysqldump db | gzip > /var/backups/db.sql.gz'
#
# 終了ステータス:
#   0-89  : 実行したジョブ本体の終了ステータスをそのまま返す
#           (別のスクリプトから呼び出したときに成否を判定できるようにするため)
#   0     : 多重起動でスキップした場合(ラッパーとしては正常動作のため0)
#   90    : 設定ファイル・ディレクトリなど、ラッパー自身の準備エラー
#   91    : 引数の指定誤り
#
# 前提:
#   同じディレクトリに job_observability.conf が配置されていること。
#   (環境変数 JOBOBS_CONF で別のファイルを指定することもできる。
#    検証環境で本番用のパスを汚さずにテストしたいときに使う)
# =====================================================================

set -u
# -u : 未定義の変数を参照したらエラーで停止する(設定ファイルの書き忘れを早期発見)。
#
# あえて -e(エラーで即終了)は付けていない。
# このスクリプトの仕事は「ジョブが失敗したことを記録して通知する」ことなので、
# ジョブが失敗した瞬間にラッパーごと終了してしまっては本末転倒になる。
# 各コマンドの終了ステータスは $? で自分で受け取り、自分で判断する。

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

# ----------------------------------------------------------------
# 共通関数
# ----------------------------------------------------------------

# runner_log: 監視の仕組み自身の動作を記録する
#   ジョブ本体のログとは分けておくことで、
#   「ジョブが失敗したのか」「監視の仕組みが壊れたのか」を切り分けやすくする。
runner_log() {
    local level="$1"
    shift
    printf '%s [%s] [run_job:%s] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "${JOB_ID:-N/A}" "$*" >> "$RUNNER_LOG"
}

# json_escape: 文字列をJSONの文字列値として安全な形に変換する
#   Slackへ送るJSONが壊れないように、次の3つを置き換える。
#     \ → \\ / " → \" / 改行 → \n
#   (jqが入っていないサーバーでも動くよう、sedとawkだけで処理している)
json_escape() {
    printf '%s' "$1" \
        | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
        | awk 'BEGIN { ORS = "" } { if (NR > 1) printf "\\n"; print }'
}

# notify: Slackへ通知する
#   引数1: 見出し(1行目)
#   引数2: 本文
#   Webhook URLが未設定(プレースホルダーのまま)の場合や通知が無効の場合は、
#   送信せずに RUNNER_LOG に内容を書き出すだけにする。
#   これにより、通知設定前でもラッパーの動作確認ができる。
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
        # 通知の失敗でジョブの結果を上書きしないよう、ログに残すだけにする
        runner_log "WARN" "Slack通知の送信に失敗しました: ${title}"
    fi
}

# write_record: 実行記録CSVに1行追記する
#   引数: 開始時刻 終了時刻 状態 終了ステータス 所要秒数
#   CSVには「決まった形の値」だけを書き、コマンド文字列のような
#   自由入力(カンマや改行が混ざりうる値)は入れない設計にしている。
#   こうするとCSVが壊れず、awkでの集計が単純になる。
write_record() {
    printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$1" "$2" "$JOB_ID" "$3" "$4" "$5" "$HOSTNAME_SHORT" "$$" >> "$RECORD_FILE"
}

# ----------------------------------------------------------------
# 引数チェック
# ----------------------------------------------------------------
if [ "$#" -lt 2 ]; then
    echo "使い方: $(basename "$0") <ジョブID> <実行するコマンド> [引数...]" >&2
    echo "  例: $(basename "$0") backup-daily /opt/backup-automation/backup.sh" >&2
    exit 91
fi

JOB_ID="$1"
shift

# ジョブIDはログファイル名やロックファイル名の一部になるため、
# 使える文字を限定しておく(「../」などでファイルパスを飛び越えられないようにする、
# CSVの列がカンマでずれないようにする、という2つの意味がある)
if ! printf '%s' "$JOB_ID" | grep -qE '^[A-Za-z0-9_-]+$'; then
    echo "[ERROR] ジョブIDに使えるのは半角英数字・ハイフン・アンダースコアのみです: ${JOB_ID}" >&2
    exit 91
fi

HOSTNAME_SHORT="$(hostname -s 2>/dev/null || echo unknown)"

# ----------------------------------------------------------------
# 出力先ディレクトリの準備
# ----------------------------------------------------------------
if ! mkdir -p "$JOB_LOG_DIR" "$REPORT_DIR" "$LOCK_DIR" "$(dirname "$RECORD_FILE")" "$(dirname "$RUNNER_LOG")"; then
    echo "[ERROR] 出力先ディレクトリを作成できません。権限を確認してください。" >&2
    exit 90
fi

JOB_LOG="${JOB_LOG_DIR}/${JOB_ID}.log"
LOCK_FILE="${LOCK_DIR}/${JOB_ID}.lock"

# 実行記録CSVが無ければ、見出し行を書いてから始める
# (後からawkやスプレッドシートで開いたときに列の意味が分かるようにするため)
if [ ! -f "$RECORD_FILE" ]; then
    echo "started_at,finished_at,job_id,status,exit_code,duration_sec,host,pid" > "$RECORD_FILE"
fi

# ----------------------------------------------------------------
# 多重起動の防止(flockによる排他制御)
# ----------------------------------------------------------------
# exec 9>"$LOCK_FILE" は「9番のファイル記述子(=ファイルの取っ手)を
# ロックファイルに結びつける」という意味。
# flock -n 9 で、その取っ手に対してロックの取得を試みる。
#   -n : ロックが取れなければ待たずに即座に失敗する(non-blocking)
# 待たずに諦めるのは、cronが5分ごとに起動する監視ジョブなどで
# 「待機中のプロセスが積み上がる」ことを避けるため。
#
# ロックはプロセスの終了と同時にカーネルが自動的に解放するため、
# ジョブが強制終了(kill -9)されてもロックが残り続けることはない。
exec 9>"$LOCK_FILE"

if ! flock -n 9; then
    NOW="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    write_record "$NOW" "$NOW" "SKIPPED" "-" "0"
    runner_log "WARN" "前回の実行がまだ終わっていないため、今回の起動をスキップしました"

    if [ "$NOTIFY_ON_SKIP" = "true" ]; then
        notify ":warning: cronジョブの多重起動を防止しました (${JOB_ID})" \
            "$(printf 'ホスト: %s\n発生時刻: %s\n前回の実行がまだ終わっていないため、今回の起動をスキップしました。\nジョブの所要時間が実行間隔を超えていないか確認してください。' \
                "$HOSTNAME_SHORT" "$NOW")"
    fi

    # ラッパーとしては「多重起動を正しく防いだ」ので、正常終了(0)として返す
    exit 0
fi

# ----------------------------------------------------------------
# ジョブ本体の実行
# ----------------------------------------------------------------
START_EPOCH="$(date '+%s')"
STARTED_AT="$(date -d "@${START_EPOCH}" '+%Y-%m-%dT%H:%M:%S%z')"

runner_log "INFO" "ジョブを開始します: $*"

# ジョブの標準出力・標準エラー出力は、まとめてジョブ別ログに追記する。
# 「>>」で追記、「2>&1」で標準エラー出力も同じ行き先にまとめる。
# cronの標準のメール通知に頼らず、出力を必ずファイルに残すのが目的。
{
    echo "===== [${STARTED_AT}] START job_id=${JOB_ID} pid=$$ cmd=$* ====="
} >> "$JOB_LOG"

# 末尾の「9>&-」は、ロック用のファイル記述子9番を
# ジョブ側のプロセスには引き継がせない(閉じる)という指定。
# これを書かないと、ジョブがバックグラウンドプロセスを起こして終了した場合に、
# その子プロセスがロックを掴んだままになり、
# ラッパーが終了した後もロックが解放されない状態になる。
# (06-troubleshooting.md Q3 で実際の再現手順を紹介している)
"$@" >> "$JOB_LOG" 2>&1 9>&-
EXIT_CODE=$?
# ↑ $? は「直前のコマンドの終了ステータス」。
#   別のコマンド(echoなど)を1つでも挟むと上書きされてしまうため、
#   実行の直後に必ず変数へ退避する。これがラッパー方式の心臓部にあたる。

END_EPOCH="$(date '+%s')"
FINISHED_AT="$(date -d "@${END_EPOCH}" '+%Y-%m-%dT%H:%M:%S%z')"
DURATION=$(( END_EPOCH - START_EPOCH ))

if [ "$EXIT_CODE" -eq 0 ]; then
    STATUS="SUCCESS"
else
    STATUS="FAILED"
fi

{
    echo "===== [${FINISHED_AT}] END   job_id=${JOB_ID} status=${STATUS} exit=${EXIT_CODE} duration=${DURATION}s ====="
} >> "$JOB_LOG"

write_record "$STARTED_AT" "$FINISHED_AT" "$STATUS" "$EXIT_CODE" "$DURATION"
runner_log "INFO" "ジョブが終了しました: status=${STATUS} exit=${EXIT_CODE} duration=${DURATION}s"

# ----------------------------------------------------------------
# 失敗時の通知
# ----------------------------------------------------------------
if [ "$EXIT_CODE" -ne 0 ]; then
    LOG_TAIL="$(tail -n "$NOTIFY_LOG_LINES" "$JOB_LOG")"
    notify ":rotating_light: cronジョブが失敗しました (${JOB_ID})" \
        "$(printf 'ホスト: %s\n終了ステータス: %s\n所要時間: %s秒\n開始: %s\n終了: %s\nログ: %s\n----- ログ末尾%s行 -----\n%s' \
            "$HOSTNAME_SHORT" "$EXIT_CODE" "$DURATION" "$STARTED_AT" "$FINISHED_AT" \
            "$JOB_LOG" "$NOTIFY_LOG_LINES" "$LOG_TAIL")"
fi

# ジョブ本体の終了ステータスをそのまま返す(終了ステータスの伝播)。
# ラッパーが常に0を返してしまうと、呼び出し元から見て
# 「成功したのか失敗したのか」が分からなくなるため。
exit "$EXIT_CODE"
