#!/usr/bin/env bash
#
# =====================================================================
# backup.sh
# 案件No.2: 定期バックアップ自動化&世代管理ツール - 本体スクリプト
#
# 概要:
#   1. 指定ディレクトリ(BACKUP_SRC_DIR)を tar.gz 形式で圧縮し、
#      日付付きファイル名でバックアップ先(BACKUP_DEST_DIR)に保存する。
#   2. 保存世代数(RETENTION_DAYS)を超えた古いバックアップを
#      find コマンドで検出し、自動削除する。
#   3. 処理結果(成功/失敗/削除内容)をログファイルに記録する。
#   4. 失敗時、および空き容量が閾値を超えた場合はSlackへ通知する。
#
# 実行方法:
#   sudo /opt/backup-automation/backup.sh
#   (通常はcronから毎日AM3:00に自動実行される。src/crontab.example 参照)
#
# 前提:
#   同じディレクトリに backup.conf が配置されていること。
# =====================================================================

set -u
# -u : 未定義の変数を参照した場合にエラーで停止する(タイプミスの早期発見)。
# あえて -e は付けていない。tarやcurlが失敗しても、その後の
# 「ログ記録」「Slack通知」まで必ず実行させたいため、
# 各コマンドの終了コードを自前でチェックしてハンドリングする設計にしている。

# ----------------------------------------------------------------
# 設定ファイルの読み込み
# ----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/backup.conf"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "[ERROR] 設定ファイルが見つかりません: ${CONFIG_FILE}" >&2
    exit 1
fi

# shellcheck source=backup.conf
source "$CONFIG_FILE"

# ----------------------------------------------------------------
# 共通関数
# ----------------------------------------------------------------

# log: 日時・ログレベル付きでログファイルと標準出力の両方に出力する
#   引数1: ログレベル(INFO / WARN / ERROR)
#   引数2以降: メッセージ本文
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
}

# notify_slack: Slack Incoming Webhookへ通知メッセージを送信する
#   失敗・警告時の管理者通知に使う。curl自体が失敗しても
#   スクリプト全体を止めないよう、戻り値は判定しない。
notify_slack() {
    local message="$1"

    if [ "${ENABLE_SLACK_NOTIFY}" != "true" ]; then
        return 0
    fi

    curl -s -X POST -H 'Content-type: application/json' \
        --data "{\"text\": \"${message}\"}" \
        "${SLACK_WEBHOOK_URL}" > /dev/null
}

# ----------------------------------------------------------------
# 事前準備
# ----------------------------------------------------------------

# ログ出力先・バックアップ保存先のディレクトリが無ければ作成する
# (-p : 親ディレクトリごと作成し、既に存在してもエラーにしない)
mkdir -p "$(dirname "${LOG_FILE}")"
mkdir -p "${BACKUP_DEST_DIR}"

log "INFO" "===== バックアップ処理を開始します ====="

# バックアップ対象ディレクトリが存在するか確認する
if [ ! -d "${BACKUP_SRC_DIR}" ]; then
    log "ERROR" "バックアップ対象ディレクトリが存在しません: ${BACKUP_SRC_DIR}"
    notify_slack ":x: [バックアップ失敗] 対象ディレクトリが存在しません: ${BACKUP_SRC_DIR}"
    exit 1
fi

# ----------------------------------------------------------------
# バックアップの作成
# ----------------------------------------------------------------

TODAY="$(date '+%Y%m%d')"
BACKUP_FILE_NAME="html-backup-${TODAY}.tar.gz"
BACKUP_FILE_PATH="${BACKUP_DEST_DIR}/${BACKUP_FILE_NAME}"

log "INFO" "バックアップを作成します: ${BACKUP_FILE_PATH}"

# tar のオプション解説:
#   c = create(新規アーカイブを作成)
#   z = gzip圧縮する
#   f = 直後にアーカイブファイル名を指定する
#   -C <dir> で対象の「親ディレクトリ」に移動してから相対パスで固めることで、
#   アーカイブ内に余計な絶対パスが残らないようにしている(復元時の事故防止)。
tar -czf "${BACKUP_FILE_PATH}" \
    -C "$(dirname "${BACKUP_SRC_DIR}")" \
    "$(basename "${BACKUP_SRC_DIR}")" \
    2>> "${LOG_FILE}"

TAR_EXIT_CODE=$?

if [ "${TAR_EXIT_CODE}" -ne 0 ]; then
    log "ERROR" "バックアップ作成に失敗しました(tar終了コード: ${TAR_EXIT_CODE})"
    notify_slack ":x: [バックアップ失敗] ${BACKUP_FILE_NAME} の作成に失敗しました(終了コード: ${TAR_EXIT_CODE})"
    exit 1
fi

BACKUP_SIZE="$(du -h "${BACKUP_FILE_PATH}" | cut -f1)"
log "INFO" "バックアップ作成に成功しました(サイズ: ${BACKUP_SIZE})"

# ----------------------------------------------------------------
# 古い世代の自動削除(世代管理)
# ----------------------------------------------------------------

log "INFO" "${RETENTION_DAYS}日より古いバックアップを検索・削除します"

# find のオプション解説:
#   -type f            : ファイルのみを対象にする(ディレクトリは除外)
#   -name "パターン"    : ファイル名で絞り込み、他のファイルを誤削除しない
#   -mtime +N          : 更新日時が「N日より古い」ファイルを検索する
#                         (+7 は「7日より前 = 8日以上経過」を意味する点に注意)
OLD_BACKUPS="$(find "${BACKUP_DEST_DIR}" -type f -name "html-backup-*.tar.gz" -mtime "+${RETENTION_DAYS}")"

if [ -n "${OLD_BACKUPS}" ]; then
    while IFS= read -r old_file; do
        [ -z "${old_file}" ] && continue
        log "INFO" "古いバックアップを削除します: ${old_file}"
        rm -f "${old_file}"
    done <<< "${OLD_BACKUPS}"
else
    log "INFO" "削除対象の古いバックアップはありませんでした"
fi

# ----------------------------------------------------------------
# 空き容量チェック(発展要件)
# ----------------------------------------------------------------

# df --output=pcent : 使用率(%)の列だけを取り出す
# 出力例:
#   Use%
#    85%
# tail -n1 で数値行だけを取り、tr -dc で数字以外(空白・%)を取り除く
DISK_USAGE="$(df --output=pcent "${BACKUP_DEST_DIR}" | tail -n 1 | tr -dc '0-9')"

log "INFO" "バックアップ先の使用率: ${DISK_USAGE}%(警告閾値: ${DISK_USAGE_THRESHOLD}%)"

if [ "${DISK_USAGE}" -ge "${DISK_USAGE_THRESHOLD}" ]; then
    log "WARN" "バックアップ先の空き容量が閾値を超えています(${DISK_USAGE}% >= ${DISK_USAGE_THRESHOLD}%)"
    notify_slack ":warning: [容量警告] バックアップ先(${BACKUP_DEST_DIR})の使用率が ${DISK_USAGE}% です(閾値: ${DISK_USAGE_THRESHOLD}%)"
fi

log "INFO" "===== バックアップ処理が正常に終了しました ====="
exit 0
