#!/usr/bin/env bash
#
# log-watch-alert.sh
# ---------------------------------------------------------------------------
# 目的:
#   指定したログファイルをリアルタイムに監視し、ERROR/CRITICAL を含む行を
#   検知したら Slack Incoming Webhook 経由で通知する。
#   短時間(既定5分)に同種の検知が連続した場合はスロットリング
#   (=一定時間は再通知を抑制する仕組み)で通知の洪水を防ぐ。
#
# 使い方:
#   1. 下記「設定値」を環境変数で上書きする(systemdの EnvironmentFile=
#      からも読み込ませられる。詳細は 03-build-guide.md を参照)
#   2. 単体実行して動作確認: ./log-watch-alert.sh
#   3. 本番運用は systemd サービスとして常駐させる
#
# 依存コマンド: tail, grep, curl, jq, date, hostname, mkdir
#   (jq が入っていない場合は `sudo apt-get install -y jq` でインストールする)
# ---------------------------------------------------------------------------

# set -e はあえて使わない。tail -F は「常駐して動き続ける」ことが前提の
# コマンドであり、途中で1回失敗しただけでスクリプト全体を終了させたくない
# ため。代わりに、必須項目のチェックはこちらで個別に行う。
set -uo pipefail

# ===== 設定値(環境変数で上書き可能。既定値は右辺の ":-" 以降) ==========
# LOG_FILE          : 監視対象のログファイル
# SLACK_WEBHOOK_URL  : Slack Incoming Webhook の URL(必須。既定値なし)
# ALERT_PATTERN      : 検知対象を表す正規表現 (grep -E 形式)
# THROTTLE_SECONDS   : この秒数以内に発生した再検知は1通にまとめる
# STATE_DIR          : 直近通知時刻・抑制件数を保存する状態ファイルの置き場所
# HOSTNAME_LABEL     : Slack通知に表示するホスト名ラベル
# =============================================================================
LOG_FILE="${LOG_FILE:-/var/log/app/error.log}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
ALERT_PATTERN="${ALERT_PATTERN:-ERROR|CRITICAL}"
THROTTLE_SECONDS="${THROTTLE_SECONDS:-300}"
STATE_DIR="${STATE_DIR:-/var/lib/log-watch-alert}"
STATE_FILE="${STATE_DIR}/state.tsv"
HOSTNAME_LABEL="${HOSTNAME_LABEL:-$(hostname 2>/dev/null || echo unknown-host)}"

# ----------------------------------------------------------------------------
# ログ出力用の小さなヘルパー関数
# systemd配下で動かすと、標準出力/標準エラー出力はそのまま journald
# (systemdのログ収集の仕組み)に取り込まれるため、printfで出すだけで
# `journalctl -u log-watch-alert` から追跡できるようになる。
# ----------------------------------------------------------------------------
log_info()  { printf '[%s] [INFO]  %s\n'  "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
log_warn()  { printf '[%s] [WARN]  %s\n'  "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
log_error() { printf '[%s] [ERROR] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

# ----------------------------------------------------------------------------
# 事前チェック: 必須コマンド・必須設定が揃っているかを起動時に確認する
#
# なぜ: 「プロセスは起動しているのに通知だけ来ない」という状態は
# 気づきにくく調査に時間がかかる。起動直後に明確なエラーで落とすことで、
# 設定ミスにすぐ気づけるようにしている。
# ----------------------------------------------------------------------------
require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    log_error "コマンド '$1' が見つかりません。インストールしてから再実行してください。"
    exit 1
  }
}
require_command tail
require_command grep
require_command curl
require_command jq

if [[ -z "$SLACK_WEBHOOK_URL" ]]; then
  log_error "SLACK_WEBHOOK_URL が設定されていません。環境変数または .env ファイルで指定してください。"
  exit 1
fi

if [[ ! -f "$LOG_FILE" ]]; then
  log_error "監視対象のログファイルが見つかりません: ${LOG_FILE}"
  exit 1
fi

# 状態ファイル(スロットリング判定に使う)を保存するディレクトリを準備する。
# 中身は「最終通知エポック秒<TAB>抑制件数」の1行のみ。
mkdir -p "$STATE_DIR"
if [[ ! -f "$STATE_FILE" ]]; then
  printf '0\t0\n' > "$STATE_FILE"
fi

# ----------------------------------------------------------------------------
# Slackへ通知を送信する関数
#   $1: 検知したログ行(抜粋)
#   $2: 前回通知からこれまでに抑制した件数
# ----------------------------------------------------------------------------
send_slack_notification() {
  local matched_line="$1"
  local suppressed_count="$2"
  local now_str
  now_str="$(date '+%Y-%m-%d %H:%M:%S')"

  local suppressed_note=""
  if [[ "$suppressed_count" -gt 0 ]]; then
    suppressed_note=$'\n'"※直近 ${THROTTLE_SECONDS} 秒以内に、このほか ${suppressed_count} 件の検知を抑制しました(スロットリング)"
  fi

  # Slackに投稿する本文を組み立てる。
  # ここでは変数展開のみで済ませ、matched_line の中身をシェルとして
  # 再解釈しないようにしている(コマンドインジェクション対策)。
  local text
  text=":rotating_light: *ログ異常検知* :rotating_light:
ホスト: ${HOSTNAME_LABEL}
監視対象: ${LOG_FILE}
検知時刻: ${now_str}
検知内容(抜粋):
\`\`\`
${matched_line}
\`\`\`${suppressed_note}"

  # jq -n --arg で text の中身をJSON文字列として安全にエスケープする。
  # ログ行にはダブルクォートや改行が含まれる可能性があるため、
  # 手動で文字列連結してJSONを組み立てると壊れたJSONになりやすい。
  local payload
  payload="$(jq -n --arg text "$text" '{text: $text}')"

  local http_status
  http_status="$(curl -sS -o /dev/null -w '%{http_code}' \
    --max-time 10 \
    -X POST \
    -H 'Content-type: application/json' \
    --data "$payload" \
    "$SLACK_WEBHOOK_URL")"

  if [[ "$http_status" == "200" ]]; then
    log_info "Slack通知を送信しました(HTTP ${http_status})"
  else
    # 通知が失敗しても監視ループ自体は止めない。
    # 「通知に失敗した」という事実自体はログに残し、後から気づけるようにする。
    log_error "Slack通知の送信に失敗しました(HTTP ${http_status})"
  fi
}

# ----------------------------------------------------------------------------
# スロットリング判定
#   $1: 検知したログ行
#
# ロジック:
#   ・前回通知から THROTTLE_SECONDS 秒以上経過していれば即座に通知し、
#     状態ファイルを「今回時刻・抑制件数0」で更新する
#   ・経過していなければ通知は送らず、抑制件数だけを+1して状態ファイルを
#     更新する(次に通知するタイミングで「何件抑制したか」を一緒に伝える)
# ----------------------------------------------------------------------------
handle_match() {
  local matched_line="$1"
  local now
  now="$(date +%s)"

  local last_notify_epoch suppressed_count
  IFS=$'\t' read -r last_notify_epoch suppressed_count < "$STATE_FILE"

  # 状態ファイルが壊れている(手動で編集された、書き込み中に中断された等)
  # 場合に備えて、値が数値として妥当かを検証する。妥当でなければ
  # 初期値(0)にフォールバックし、算術式($(( )))が不正な文字列を
  # 変数名として解釈して異常終了する事故を防ぐ(べき等性の担保)。
  # なお正規表現は「先頭ゼロを含む数字列(例: 008)」も弾いている。
  # Bashの算術式は先頭ゼロの数値を8進数として解釈するため、"008"のような
  # 値を許してしまうと「8は8進数として無効な桁」で算術式がエラーになる。
  if ! [[ "$last_notify_epoch" =~ ^(0|[1-9][0-9]*)$ ]]; then
    log_warn "状態ファイルの内容が不正なため、最終通知時刻を初期値(0)として扱います: ${STATE_FILE}"
    last_notify_epoch=0
  fi
  if ! [[ "$suppressed_count" =~ ^(0|[1-9][0-9]*)$ ]]; then
    suppressed_count=0
  fi

  local elapsed=$(( now - last_notify_epoch ))

  if (( last_notify_epoch == 0 || elapsed >= THROTTLE_SECONDS )); then
    send_slack_notification "$matched_line" "$suppressed_count"
    printf '%s\t0\n' "$now" > "$STATE_FILE"
  else
    suppressed_count=$(( suppressed_count + 1 ))
    printf '%s\t%s\n' "$last_notify_epoch" "$suppressed_count" > "$STATE_FILE"
    log_info "スロットリング中のため通知を抑制しました(直近通知から${elapsed}秒 / 抑制件数${suppressed_count})"
  fi
}

# SIGTERM/SIGINT を受け取ったときに、ログを残してから終了できるようにする。
# systemd はサービス停止時に SIGTERM を送るため、これを拾うことで
# 「正常に停止した」のか「予期せず落ちた」のかをログで区別しやすくなる。
trap 'log_info "監視を停止します(終了シグナルを受信しました)"; exit 0' TERM INT

log_info "監視を開始します: ${LOG_FILE} (検知パターン: ${ALERT_PATTERN} / スロットリング: ${THROTTLE_SECONDS}秒)"

# ----------------------------------------------------------------------------
# メインループ
#
# tail -F -n 0 "$LOG_FILE" :
#   -F は "--follow=name --retry" と同じ意味。ログローテートでファイルが
#   一旦消えて新しく作り直されても、同じファイル名を追いかけ直してくれる。
#   小文字の -f だとファイルディスクリプタ(開いた時点のファイル実体)を
#   追いかけるだけなので、ローテート後に取りこぼしが発生する。
#   -n 0 は「起動時点で既にある行は読まず、これ以降に追記された行だけを
#   対象にする」という指定。過去ログを毎回全部読み直して二重通知しない
#   ようにするため。
#
# grep -Eq "$ALERT_PATTERN" :
#   -E は拡張正規表現(ERE)を使うモード。"ERROR|CRITICAL" のように
#   "|" で「どちらかを含む(OR条件)」を素直に書けるようにするため指定する。
#   -q は一致・不一致だけを終了コードで返し、画面には何も出力しないモード
#   (行の中身は $line 側で既に持っているので、grep側の出力は不要なため)。
#
# < <(...) というプロセス置換(=コマンドの出力をあたかもファイルのように
# 読み込ませる仕組み)を使い、"tail | while" のように単純パイプで繋がない
# ようにしている。単純パイプだと while ループが別プロセス(サブシェル)に
# なってしまい、上で仕掛けた trap がこのシェルの中で発火しなくなる
# (= systemctl stop で SIGTERM を送っても掴めず、綺麗に終了できない)ため。
# ----------------------------------------------------------------------------
while IFS= read -r line; do
  if grep -Eq "$ALERT_PATTERN" <<< "$line"; then
    handle_match "$line"
  fi
done < <(tail -F -n 0 "$LOG_FILE")
