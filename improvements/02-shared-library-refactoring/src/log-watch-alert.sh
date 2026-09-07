#!/usr/bin/env bash
#
# log-watch-alert.sh(改善版 / After)
# ---------------------------------------------------------------------------
# 改善案件No.2: 共通ライブラリ opslib.sh を使うように書き換えたもの
#
# 元ファイル: projects/03-log-monitoring-alert/src/log-watch-alert.sh
#   元ファイルは「改善前(Before)の証拠」としてそのまま残してあるため、
#   このファイルと見比べれば、どこがどう変わったのかが分かる。
#
# 変わったところ(3か所だけ):
#   1. log_info / log_warn / log_error の定義 -> 削除し、ops_log_* を使用
#   2. require_command() の定義とその4回の呼び出し
#      -> ops_require_commands tail grep curl jq の1行に集約
#   3. send_slack_notification() の中の jq + curl 部分
#      -> ops_notify_slack に委譲(本文の組み立てだけこのファイルに残す)
#
# 注意した点(変数名の衝突):
#   このスクリプトの LOG_FILE は「監視する対象のログファイル」を指す。
#   一方、案件No.2 / No.4 の LOG_FILE は「自分が出力するログファイル」で、
#   同じ名前なのに意味が正反対だった。共通ライブラリでは出力先を
#   OPS_LOG_FILE という別の名前にすることで、この取り違えを防いでいる。
#
# 変わっていないところ:
#   ・環境変数(LOG_FILE / SLACK_WEBHOOK_URL / ALERT_PATTERN /
#     THROTTLE_SECONDS / STATE_DIR / HOSTNAME_LABEL)の名前と意味
#   ・スロットリングの判定ロジックと状態ファイルの書式
#   ・systemd サービスとして常駐させる運用方法
#   ・Slackへ投稿されるメッセージの文面
#
# 目的:
#   指定したログファイルをリアルタイムに監視し、ERROR/CRITICAL を含む行を
#   検知したら Slack Incoming Webhook 経由で通知する。
#   短時間(既定5分)に同種の検知が連続した場合はスロットリング
#   (=一定時間は再通知を抑制する仕組み)で通知の洪水を防ぐ。
#
# 依存コマンド: tail, grep, curl, jq, date, hostname, mkdir
#
# 前提: 同じディレクトリに opslib.sh が配置されていること。
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
# 共通ライブラリの読み込み
#
# ${BASH_SOURCE[0]} は「このファイル自身のパス」を常に指す。
# systemd から絶対パスで起動されても、手元で ./log-watch-alert.sh と
# 相対パスで起動しても、同じディレクトリの opslib.sh を確実に見つけられる。
# ----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f "${SCRIPT_DIR}/opslib.sh" ]]; then
  echo "エラー: 共通ライブラリが見つかりません: ${SCRIPT_DIR}/opslib.sh" >&2
  exit 1
fi

# shellcheck source=./opslib.sh
source "${SCRIPT_DIR}/opslib.sh"

# ----------------------------------------------------------------------------
# 共通ライブラリへの設定の引き渡し
#
# OPS_LOG_FILE はあえて空のままにしている(既定値が空)。
# このスクリプトは systemd 配下で常駐し、標準出力/標準エラー出力は
# そのまま journald(systemdのログ収集の仕組み)に取り込まれるため、
# 自前でログファイルを持つ必要がないという改善前からの方針を維持する。
# ----------------------------------------------------------------------------

# OPS_LOG_TAG: journalctl やログ集約基盤で出力元を判別するための識別子。
# 既定はスクリプト名から自動生成されるが、ここでは明示しておく。
# 以下の2変数は opslib.sh の中の関数が参照する。解析ツールは既定では
# source 先まで読まないため「未使用」と誤検知される(SC2034)ので抑止する。
# shellcheck disable=SC2034
OPS_LOG_TAG="log-watch-alert"
# shellcheck disable=SC2034
OPS_SLACK_WEBHOOK_URL="$SLACK_WEBHOOK_URL"

# ----------------------------------------------------------------------------
# 事前チェック: 必須コマンド・必須設定が揃っているかを起動時に確認する
#
# なぜ: 「プロセスは起動しているのに通知だけ来ない」という状態は
# 気づきにくく調査に時間がかかる。起動直後に明確なエラーで落とすことで、
# 設定ミスにすぐ気づけるようにしている。
#
# 改善前は require_command() を自前で定義し、4回に分けて呼んでいた。
# 旧実装は1つ足りない時点で exit していたため、jq を入れて再実行して
# はじめて curl も無いと分かる、という二度手間が起きる作りだった。
# ops_require_commands は足りないものをすべて列挙してから戻り値で返す。
# ----------------------------------------------------------------------------
if ! ops_require_commands tail grep curl jq; then
  exit 1
fi

if [[ -z "$SLACK_WEBHOOK_URL" ]]; then
  ops_log_error "SLACK_WEBHOOK_URL が設定されていません。環境変数または .env ファイルで指定してください。"
  exit 1
fi

if [[ ! -f "$LOG_FILE" ]]; then
  ops_log_error "監視対象のログファイルが見つかりません: ${LOG_FILE}"
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
#
# 改善のポイント:
#   「通知の本文をどう組み立てるか」はこのスクリプト固有の関心事なので
#   ここに残し、「JSONへのエスケープ・HTTP送信・結果のログ記録」という
#   どのスクリプトでも同じ処理は ops_notify_slack に委譲した。
#   この線引きにより、通知の見た目を変えたいときはこのファイルだけを、
#   送信方法を変えたいときはライブラリだけを触ればよくなる。
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

  # 送信は共通ライブラリに任せる。
  # JSONのエスケープ(jq)・タイムアウト・HTTPステータスの判定・
  # 成否のログ記録はすべて ops_notify_slack の中で行われる。
  # 戻り値もそのまま呼び出し元へ返す(0=成功 / 1=送信失敗 / 2=設定不足)。
  ops_notify_slack "$text"
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
    ops_log_warn "状態ファイルの内容が不正なため、最終通知時刻を初期値(0)として扱います: ${STATE_FILE}"
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
    ops_log_info "スロットリング中のため通知を抑制しました(直近通知から${elapsed}秒 / 抑制件数${suppressed_count})"
  fi
}

# SIGTERM/SIGINT を受け取ったときに、ログを残してから終了できるようにする。
# systemd はサービス停止時に SIGTERM を送るため、これを拾うことで
# 「正常に停止した」のか「予期せず落ちた」のかをログで区別しやすくなる。
trap 'ops_log_info "監視を停止します(終了シグナルを受信しました)"; exit 0' TERM INT

ops_log_info "監視を開始します: ${LOG_FILE} (検知パターン: ${ALERT_PATTERN} / スロットリング: ${THROTTLE_SECONDS}秒)"

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
