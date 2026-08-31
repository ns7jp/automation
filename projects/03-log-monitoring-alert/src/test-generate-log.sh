#!/usr/bin/env bash
#
# test-generate-log.sh
# ---------------------------------------------------------------------------
# 目的:
#   log-watch-alert.sh の動作確認用に、疑似的なアプリケーションログを
#   1行ずつ追記するスクリプト。本物のアプリが無くても、監視・通知・
#   スロットリングの動作をこれだけで一通り検証できる。
#
# 使い方:
#   ./test-generate-log.sh                # INFOログを1行だけ追記
#   ./test-generate-log.sh ERROR          # ERRORログを1行追記
#   ./test-generate-log.sh CRITICAL 5     # CRITICALログを0.5秒間隔で5回連続追記
#                                          # (スロットリングの抑制動作を
#                                          #  確認したいときに使う)
#
# 環境変数 LOG_FILE で出力先を変更できる(既定値は本番と同じパス)。
#   LOG_FILE=/tmp/error.log ./test-generate-log.sh ERROR
# ---------------------------------------------------------------------------

set -euo pipefail

LOG_FILE="${LOG_FILE:-/var/log/app/error.log}"
LEVEL="${1:-INFO}"
COUNT="${2:-1}"

# 出力先ディレクトリが無ければ作成する(初回実行時のつまずきを防ぐため)
mkdir -p "$(dirname "$LOG_FILE")"

for ((i = 1; i <= COUNT; i++)); do
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "${timestamp} [${LEVEL}] サンプルログメッセージです(連番: ${i}/${COUNT})" >> "$LOG_FILE"
  # 複数行を書くときは、tail -F側が1行ずつ読み取れるよう少し間隔を空ける
  sleep 0.5
done

echo "書き込み完了: ${LOG_FILE} に [${LEVEL}] を ${COUNT} 件追記しました"
