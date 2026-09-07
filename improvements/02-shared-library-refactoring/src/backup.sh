#!/usr/bin/env bash
#
# =====================================================================
# backup.sh(改善版 / After)
# 改善案件No.2: 共通ライブラリ opslib.sh を使うように書き換えたもの
#
# 元ファイル: projects/02-backup-automation/src/backup.sh
#   元ファイルは「改善前(Before)の証拠」としてそのまま残してあるため、
#   このファイルと見比べれば、どこがどう変わったのかが分かる。
#
# 変わったところ(3か所だけ):
#   1. 設定ファイルの読み込み  -> ops_load_config に置き換え
#   2. log() 関数の定義         -> 削除し、ops_log を使用
#   3. notify_slack() 関数の定義 -> 削除し、ops_notify_slack を使用
#
# 変わっていないところ:
#   ・backup.conf の書式(既存の設定ファイルをそのまま使える=後方互換)
#   ・tar でのバックアップ、find での世代管理、df での容量チェックという
#     このスクリプト本来の処理内容
#   ・cron から呼ばれる際の実行方法と終了ステータスの意味
#
# 実行方法:
#   sudo /opt/backup-automation/backup.sh
#
# 前提:
#   同じディレクトリに backup.conf と opslib.sh が配置されていること。
# =====================================================================

set -u
# -u : 未定義の変数を参照した場合にエラーで停止する(タイプミスの早期発見)。
# あえて -e は付けていない。tarやcurlが失敗しても、その後の
# 「ログ記録」「Slack通知」まで必ず実行させたいため、
# 各コマンドの終了コードを自前でチェックしてハンドリングする設計にしている。

# ----------------------------------------------------------------
# 共通ライブラリの読み込み
#
# なぜ ${BASH_SOURCE[0]} を使うのか:
#   $0 は「どう起動されたか」で中身が変わる(cronから絶対パスで呼ばれる、
#   シンボリックリンク経由で呼ばれる等)。${BASH_SOURCE[0]} は
#   「このファイル自身のパス」を常に指すため、スクリプトの置き場所を
#   基準に相対パスを組み立てたいときはこちらを使うのが確実。
#   cd して pwd を取ることで、相対パスを絶対パスに変換している。
# ----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "${SCRIPT_DIR}/opslib.sh" ]; then
    echo "[ERROR] 共通ライブラリが見つかりません: ${SCRIPT_DIR}/opslib.sh" >&2
    exit 1
fi

# shellcheck source=./opslib.sh
source "${SCRIPT_DIR}/opslib.sh"

# ----------------------------------------------------------------
# 設定ファイルの読み込み
#
# 旧実装では「存在チェック -> エラーメッセージ -> exit -> source」を
# 自前で9行書いていた。ライブラリの ops_load_config が同じことを行い、
# さらに「読み取り権限の確認」「権限が緩い場合の警告」まで面倒を見る。
#
# ops_load_config はライブラリの方針どおり exit せず戻り値を返すので、
# 「どう終了するか」はこの呼び出し側で決める(ここでは exit 1)。
# ----------------------------------------------------------------
CONFIG_FILE="${SCRIPT_DIR}/backup.conf"

if ! ops_load_config "$CONFIG_FILE"; then
    exit 1
fi

# ----------------------------------------------------------------
# 設定値をライブラリへ引き渡す(後方互換のための橋渡し)
#
# backup.conf は改善前から LOG_FILE / ENABLE_SLACK_NOTIFY /
# SLACK_WEBHOOK_URL という名前で値を持っている。
# 運用中の設定ファイルを書き換えずに済ませるため、ここで
# ライブラリが使う OPS_* 変数へ移し替えるだけにしている。
#
# なぜ設定ファイル側を OPS_* に書き換えないのか:
#   本番サーバー上の設定ファイルを書き換える作業は、それ自体が
#   作業ミスによる障害の原因になる。「スクリプトを差し替えるだけで
#   移行が完了する」状態にしておくほうが、切り戻しも簡単になる。
# ----------------------------------------------------------------
if ! ops_log_init "$LOG_FILE"; then
    exit 1
fi

# 以下2つの変数は opslib.sh の ops_notify_slack が参照する。
# ただし解析ツールは既定では source 先(opslib.sh)まで読まないため、
# 「代入しただけで使っていない変数」だと誤検知される(SC2034)。
# 実際には使われているので、その行だけ警告を抑止する。
# (`shellcheck -x after/backup.sh` のように -x を付ければ抑止なしでも警告は出ない)
#
# 補足: 「# から始まり shellcheck という語で始まる行」は指示行として
# 解釈されるため、説明文をその語で書き始めないよう注意する。
# shellcheck disable=SC2034
OPS_SLACK_ENABLED="$ENABLE_SLACK_NOTIFY"
# shellcheck disable=SC2034
OPS_SLACK_WEBHOOK_URL="$SLACK_WEBHOOK_URL"

# ----------------------------------------------------------------
# 事前準備
# ----------------------------------------------------------------

# バックアップ保存先のディレクトリが無ければ作成する
# (-p : 親ディレクトリごと作成し、既に存在してもエラーにしない)
# ※ ログ出力先のディレクトリ作成は ops_log_init が済ませている。
mkdir -p "${BACKUP_DEST_DIR}"

ops_log_info "===== バックアップ処理を開始します ====="

# バックアップ対象ディレクトリが存在するか確認する
if [ ! -d "${BACKUP_SRC_DIR}" ]; then
    ops_log_error "バックアップ対象ディレクトリが存在しません: ${BACKUP_SRC_DIR}"
    ops_notify_slack ":x: [バックアップ失敗] 対象ディレクトリが存在しません: ${BACKUP_SRC_DIR}"
    exit 1
fi

# ----------------------------------------------------------------
# バックアップの作成
# ----------------------------------------------------------------

TODAY="$(date '+%Y%m%d')"
BACKUP_FILE_NAME="html-backup-${TODAY}.tar.gz"
BACKUP_FILE_PATH="${BACKUP_DEST_DIR}/${BACKUP_FILE_NAME}"

ops_log_info "バックアップを作成します: ${BACKUP_FILE_PATH}"

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
    ops_log_error "バックアップ作成に失敗しました(tar終了コード: ${TAR_EXIT_CODE})"
    ops_notify_slack ":x: [バックアップ失敗] ${BACKUP_FILE_NAME} の作成に失敗しました(終了コード: ${TAR_EXIT_CODE})"
    exit 1
fi

BACKUP_SIZE="$(du -h "${BACKUP_FILE_PATH}" | cut -f1)"
ops_log_info "バックアップ作成に成功しました(サイズ: ${BACKUP_SIZE})"

# ----------------------------------------------------------------
# 古い世代の自動削除(世代管理)
# ----------------------------------------------------------------

ops_log_info "${RETENTION_DAYS}日より古いバックアップを検索・削除します"

# find のオプション解説:
#   -type f            : ファイルのみを対象にする(ディレクトリは除外)
#   -name "パターン"    : ファイル名で絞り込み、他のファイルを誤削除しない
#   -mtime +N          : 更新日時が「N日より古い」ファイルを検索する
#                         (+7 は「7日より前 = 8日以上経過」を意味する点に注意)
OLD_BACKUPS="$(find "${BACKUP_DEST_DIR}" -type f -name "html-backup-*.tar.gz" -mtime "+${RETENTION_DAYS}")"

if [ -n "${OLD_BACKUPS}" ]; then
    while IFS= read -r old_file; do
        [ -z "${old_file}" ] && continue
        ops_log_info "古いバックアップを削除します: ${old_file}"
        rm -f "${old_file}"
    done <<< "${OLD_BACKUPS}"
else
    ops_log_info "削除対象の古いバックアップはありませんでした"
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

ops_log_info "バックアップ先の使用率: ${DISK_USAGE}%(警告閾値: ${DISK_USAGE_THRESHOLD}%)"

if [ "${DISK_USAGE}" -ge "${DISK_USAGE_THRESHOLD}" ]; then
    ops_log_warn "バックアップ先の空き容量が閾値を超えています(${DISK_USAGE}% >= ${DISK_USAGE_THRESHOLD}%)"
    ops_notify_slack ":warning: [容量警告] バックアップ先(${BACKUP_DEST_DIR})の使用率が ${DISK_USAGE}% です(閾値: ${DISK_USAGE_THRESHOLD}%)"
fi

ops_log_info "===== バックアップ処理が正常に終了しました ====="
exit 0
