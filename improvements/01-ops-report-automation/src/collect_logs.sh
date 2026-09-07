#!/usr/bin/env bash
#
# =====================================================================
# collect_logs.sh
# 改善案件No.1: 月次運用報告書の自動生成 - ログ収集スクリプト
#
# 目的:
#   各サーバーに散らばっている backup.log を、レポート生成サーバーの
#   1か所(ops_report.conf の BACKUP_LOG_ROOT)に集めてくる。
#   ops_report.sh は「集まったログ」を読むだけにして、
#   「集める処理」と「集計する処理」を分けている(責務の分離)。
#
# 実行方法:
#   ./collect_logs.sh
#
# 前提:
#   - 同じディレクトリに ops_report.conf と servers.conf があること
#   - 収集先サーバーへSSH公開鍵認証でパスワードなしログインできること
#     (cronから無人実行するため。パスワード入力が必要だと自動化できない)
#
# 【なぜ scp ではなく rsync を使うのか】
#   rsync は「前回から変わった差分だけ」を転送する。
#   ログは毎日少しずつ追記されるファイルなので、毎回まるごと
#   コピーするより転送量も時間も小さくて済む。
#   rsync が入っていない環境向けに scp へのフォールバックも用意している。
# =====================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${OPS_REPORT_CONF:-${SCRIPT_DIR}/ops_report.conf}"
SERVERS_FILE="${OPS_SERVERS_CONF:-${SCRIPT_DIR}/servers.conf}"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "[ERROR] 設定ファイルが見つかりません: ${CONFIG_FILE}" >&2
    exit 1
fi
if [ ! -f "$SERVERS_FILE" ]; then
    echo "[ERROR] サーバー一覧が見つかりません: ${SERVERS_FILE}" >&2
    exit 1
fi

# shellcheck source=ops_report.conf
source "$CONFIG_FILE"

log() {
    local level="$1"
    shift
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "${timestamp} [${level}] $*" | tee -a "$LOG_FILE" >&2
}

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
mkdir -p "$BACKUP_LOG_ROOT"

log "INFO" "===== ログ収集を開始します(収集先: ${BACKUP_LOG_ROOT}) ====="

# 集計結果のカウンター
OK_COUNT=0
NG_COUNT=0

while IFS=',' read -r name ssh_target remote_path; do
    # "#" で始まる行(コメント)と空行はスキップする
    [[ -z "$name" || "$name" == \#* ]] && continue

    dest_dir="${BACKUP_LOG_ROOT}/${name}"
    mkdir -p "$dest_dir"
    dest_file="${dest_dir}/${BACKUP_LOG_NAME}"

    if [ "$ssh_target" = "localhost" ]; then
        # 検証環境用: SSHを使わず、同じマシンのファイルをコピーする
        if cp "$remote_path" "$dest_file" 2>/dev/null; then
            log "INFO" "${name}: ローカルコピー成功(${remote_path})"
            OK_COUNT=$((OK_COUNT + 1))
        else
            log "ERROR" "${name}: ローカルコピー失敗(${remote_path} が読めません)"
            NG_COUNT=$((NG_COUNT + 1))
        fi
        continue
    fi

    if command -v rsync > /dev/null 2>&1; then
        # -a : パーミッションや更新日時を保ったままコピーする
        # -z : 転送中に圧縮する(テキストログはよく縮むので効果が大きい)
        # -q : 余計な進捗表示を出さない(cronからの実行を想定)
        # -e : SSH側のオプションを指定する
        #      ConnectTimeout=10 → 応答のないサーバーで固まらないようにする
        if rsync -azq -e "ssh -o ConnectTimeout=10 -o BatchMode=yes" \
                "${ssh_target}:${remote_path}" "$dest_file"; then
            log "INFO" "${name}: rsyncで収集成功(${ssh_target}:${remote_path})"
            OK_COUNT=$((OK_COUNT + 1))
        else
            log "ERROR" "${name}: rsyncで収集失敗(${ssh_target}:${remote_path})"
            NG_COUNT=$((NG_COUNT + 1))
        fi
    else
        # rsync が無い環境向けのフォールバック
        if scp -q -o ConnectTimeout=10 -o BatchMode=yes \
                "${ssh_target}:${remote_path}" "$dest_file"; then
            log "INFO" "${name}: scpで収集成功(${ssh_target}:${remote_path})"
            OK_COUNT=$((OK_COUNT + 1))
        else
            log "ERROR" "${name}: scpで収集失敗(${ssh_target}:${remote_path})"
            NG_COUNT=$((NG_COUNT + 1))
        fi
    fi
done < "$SERVERS_FILE"

log "INFO" "ログ収集完了: 成功 ${OK_COUNT}台 / 失敗 ${NG_COUNT}台"

# 【設計上の判断】
#   1台でも収集に失敗したら「異常終了(exit 1)」にする。
#   ただしその場合でも ops_report.sh 側は「読めたログだけ」で
#   レポートを作れるようにしてあるため、月次報告が
#   まるごと出せなくなることはない(運用を止めない設計)。
if [ "$NG_COUNT" -gt 0 ]; then
    log "WARN" "収集に失敗したサーバーがあります。レポートはそのサーバーを除いて生成されます"
    exit 1
fi

log "INFO" "===== ログ収集が正常に終了しました ====="
exit 0
