#!/usr/bin/env bash
#
# =====================================================================
# sample_job.sh
# 改善案件No.4: cronのサイレント障害を実行結果の可視化と失敗検知で撲滅
#   - 検証用のダミージョブ
#
# 概要:
#   本物のバックアップやDBダンプを壊さずに、
#   「わざと失敗させる」「わざと長引かせる」テストを行うためのスクリプト。
#   05-effect-measurement.md のテストと 04-build-guide.md の動作確認で使う。
#
# 使い方:
#   sample_job.sh              … 成功する(終了ステータス0)
#   sample_job.sh --fail [N]   … 終了ステータス N(既定3)で失敗する
#   sample_job.sh --sleep N    … N秒かかってから成功する(多重起動テスト用)
#
# 例:
#   run_job.sh sample-job /opt/cron-job-observability/sample_job.sh --fail
#   run_job.sh sample-job /opt/cron-job-observability/sample_job.sh --sleep 30
# =====================================================================

set -u

MODE="${1:-ok}"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] sample_job.sh を開始します (mode=${MODE})"

case "$MODE" in
    --fail)
        # 「処理の途中で異常が起きた」状況を再現する。
        # 終了ステータスを指定できるようにしているのは、
        # 「0以外なら何番でも失敗として扱えるか」を確認するため。
        CODE="${2:-3}"
        echo "[ERROR] 疑似的な障害を発生させます (exit ${CODE})" >&2
        echo "[ERROR] 例: バックアップ先ディレクトリに書き込めませんでした" >&2
        exit "$CODE"
        ;;
    --sleep)
        # 「処理が想定より長引いた」状況を再現する。
        # 実行間隔より長いスリープを指定すると多重起動のテストになる。
        SECONDS_TO_SLEEP="${2:-30}"
        echo "${SECONDS_TO_SLEEP}秒かけて処理を行うふりをします"
        sleep "$SECONDS_TO_SLEEP"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 長時間処理が完了しました"
        exit 0
        ;;
    *)
        echo "通常の処理が完了しました"
        exit 0
        ;;
esac
