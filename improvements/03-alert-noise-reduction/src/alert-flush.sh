#!/usr/bin/env bash
# =====================================================================
# alert-flush.sh
# 改善案件No.3: アラート過多の改善 - 集約ウィンドウの締め処理
#
# ■ 何をするスクリプトか
#   期限が過ぎた集約ウィンドウを閉じて、「まとめ通知」を1件送る。
#
# ■ なぜ別スクリプトなのか
#   集約は「一定時間ためて、あとで1件にまとめる」仕組みなので、
#   ためている間に新しい通知が1件も来ないと、誰も締めてくれない。
#   例: 10分ウィンドウの最後の通知が来たあと、次の通知が3時間後だと、
#       そのまとめ通知が3時間遅れて届いてしまう。
#   そこで cron から5分ごとにこのスクリプトを動かし、
#   「時間が来たウィンドウを閉じて回る」係を用意している。
#
# ■ 使い方
#   ./alert-flush.sh
#   cron 登録例は crontab.example を参照(5分ごと)。
#
# ■ 依存コマンド: bash 4.0以降, date, jq, curl, tr
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

ar_require_command date jq curl tr || exit 1

# まとめ通知の本文にルールの説明を載せるため、ルール定義を読み込む
if ! ar_load_rules "$AR_RULES_FILE"; then
    exit 1
fi

now_epoch="$(ar_now_epoch)"

# 締める前のウィンドウ数を数えておく(処理結果をログに残すため)
before_count=0
if [[ -d "$AR_DATA_DIR" ]]; then
    for state_file in "${AR_DATA_DIR}"/agg_*.tsv; do
        [[ -e "$state_file" ]] || continue
        before_count=$((before_count + 1))
    done
fi

ar_flush_expired "$now_epoch"

after_count=0
if [[ -d "$AR_DATA_DIR" ]]; then
    for state_file in "${AR_DATA_DIR}"/agg_*.tsv; do
        [[ -e "$state_file" ]] || continue
        after_count=$((after_count + 1))
    done
fi

ar_log INFO "集約ウィンドウの締め処理が完了しました(処理前 ${before_count} 件 → 処理後 ${after_count} 件)"

exit 0
