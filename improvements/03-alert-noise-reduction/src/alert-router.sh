#!/usr/bin/env bash
# =====================================================================
# alert-router.sh
# 改善案件No.3: アラート過多の改善 - 通知の入口(振り分け本体)
#
# ■ 何をするスクリプトか
#   監視ツールが出した通知を1件受け取り、
#     1. 全件記録(records.jsonl)に必ず残し
#     2. ルール定義ファイルで重要度(P1/P2/P3)を判定し
#     3. 同種の連続通知は集約し、まったく同じ文面の再送は重複排除し
#     4. 重要度に応じた通知先へ振り分ける
#   ところまでを行う。
#
# ■ 既存ツールからの呼び出し方
#   これまで各ツールが直接 Slack へ curl していた部分を、
#   このスクリプトの呼び出しに差し替える。
#     旧: curl -X POST --data "{\"text\":\"$msg\"}" "$SLACK_WEBHOOK_URL"
#     新: /opt/alert-router/alert-router.sh \
#           --source health-check --host web01 --message "$msg"
#
# ■ 使い方
#   単発の通知を処理する:
#     ./alert-router.sh --source health-check --host web01 --message "本文"
#   標準入力から本文を受け取る(複数行の通知に便利):
#     printf '%s' "$msg" | ./alert-router.sh --source log-watch --host app01 --message -
#   過去ログをまとめて流し込んで検証する:
#     ./alert-router.sh --replay sample-alerts.tsv
#   ルール定義ファイルの妥当性だけを確認する:
#     ./alert-router.sh --check-rules
#
# ■ 依存コマンド: bash 4.0以降, date, jq, curl, tr, md5sum
# =====================================================================

# set -e はあえて使わない。1件の通知処理でエラーが起きても、
# 残りの通知処理を続けたいため(通知基盤が全部止まる方が危険)。
# -u(未定義変数をエラー)と -o pipefail(パイプ途中の失敗を拾う)は有効にする。
set -uo pipefail

# このスクリプトが置かれているディレクトリを絶対パスで求める。
# cron から呼ばれると作業ディレクトリが変わるため、
# 相対パスで設定ファイルを探すと「手元では動くのにcronでは動かない」となる。
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

usage() {
    cat <<'USAGE'
使い方:
  alert-router.sh --source <発生元> --host <ホスト名> --message <本文>
  alert-router.sh --replay <過去ログファイル>
  alert-router.sh --check-rules

オプション:
  --source <名前>   通知の発生元(例: health-check / log-watch / backup)
  --host <名前>     対象ホスト名(省略時は自ホスト名)
  --message <本文>  通知本文。"-" を指定すると標準入力から読み込む
  --at "<日時>"     発生日時を明示する("YYYY-MM-DD HH:MM:SS"形式。省略時は現在時刻)
  --replay <ファイル>
                    タブ区切りの過去ログ(日時<TAB>発生元<TAB>ホスト<TAB>本文)を
                    先頭から順に流し込む。効果測定・検証用
  --check-rules     ルール定義ファイルを読み込んで一覧表示する(通知はしない)
  -h, --help        このヘルプを表示する
USAGE
}

# ---------------------------------------------------------------------
# 引数の解析
# ---------------------------------------------------------------------
opt_source=""
opt_host=""
opt_message=""
opt_at=""
opt_replay=""
opt_check_rules="false"
has_message="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source)  opt_source="${2:-}"; shift 2 ;;
        --host)    opt_host="${2:-}"; shift 2 ;;
        --message) opt_message="${2:-}"; has_message="true"; shift 2 ;;
        --at)      opt_at="${2:-}"; shift 2 ;;
        --replay)  opt_replay="${2:-}"; shift 2 ;;
        --check-rules) opt_check_rules="true"; shift ;;
        -h|--help) usage; exit 0 ;;
        *)
            printf '[ERROR] 不明なオプションです: %s\n' "$1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------
# 事前チェックと初期化
# ---------------------------------------------------------------------
ar_require_command date jq curl tr md5sum || exit 1

mkdir -p "$AR_DATA_DIR" "$AR_LOG_DIR" "$AR_SUMMARY_DIR"

if ! ar_load_rules "$AR_RULES_FILE"; then
    exit 1
fi

# --check-rules: 読み込んだルールを表として表示して終了する。
# ルールを書き換えたあと、本番に反映する前に必ず実行して確認する。
if [[ "$opt_check_rules" == "true" ]]; then
    printf '\n%-8s %-4s %-9s %-8s %s\n' "ID" "重要度" "通知先" "集約(秒)" "説明"
    printf -- '---------------------------------------------------------------------------\n'
    for rule_id in "${AR_RULE_IDS[@]}"; do
        printf '%-8s %-4s %-9s %-8s %s\n' \
            "$rule_id" \
            "${AR_RULE_SEVERITY[$rule_id]}" \
            "${AR_RULE_CHANNEL[$rule_id]}" \
            "${AR_RULE_WINDOW[$rule_id]}" \
            "${AR_RULE_DESC[$rule_id]}"
    done
    printf -- '---------------------------------------------------------------------------\n'
    printf 'ルール定義は正常です(%d 件)。未分類の通知は %s として扱われます。\n\n' \
        "${#AR_RULE_IDS[@]}" "$AR_UNMATCHED_SEVERITY"
    exit 0
fi

# ---------------------------------------------------------------------
# --replay: 過去ログを先頭から順に流し込む
#
# なぜ必要か:
#   「ルールを変えたら通知は何件になるのか」を、本番の通知に一切
#   影響を与えずに確かめたい。過去ログを流し込めば、実際の1日分の
#   通知に対する結果を数分で得られる。
#
# 実装上のポイント:
#   集約ウィンドウは「時間」で判定するので、流し込むときも
#   現在時刻ではなくログに記録された発生日時を使う。
#   1件処理するたびに ar_flush_expired を呼び、仮想の時計を
#   進めながらウィンドウを閉じていく。
# ---------------------------------------------------------------------
if [[ -n "$opt_replay" ]]; then
    if [[ ! -f "$opt_replay" ]]; then
        ar_log ERROR "過去ログファイルが見つかりません: ${opt_replay}"
        exit 1
    fi

    ar_log INFO "過去ログの流し込みを開始します: ${opt_replay}(モード: ${AR_MODE})"

    replay_count=0
    last_epoch=0
    while IFS=$'\t' read -r r_ts r_source r_host r_message; do
        [[ -z "${r_ts// /}" ]] && continue
        [[ "$r_ts" == \#* ]] && continue

        if ! r_epoch="$(date -d "$r_ts" +%s 2>/dev/null)"; then
            ar_log WARN "日時として解釈できない行をスキップしました: ${r_ts}"
            continue
        fi

        ar_flush_expired "$r_epoch"
        ar_handle_event "$r_ts" "$r_epoch" "${r_source:-unknown}" "${r_host:-unknown}" "${r_message:-}"

        last_epoch="$r_epoch"
        replay_count=$((replay_count + 1))
    done <"$opt_replay"

    # 最後に残ったウィンドウを、十分に未来の時刻を渡して全部閉じる
    # (2日分先に進めれば、最長の集約ウィンドウ86400秒も必ず期限切れになる)。
    if [[ "$last_epoch" -gt 0 ]]; then
        ar_flush_expired $((last_epoch + 172800))
    fi

    ar_log INFO "過去ログの流し込みが完了しました: ${replay_count} 件を処理"
    exit 0
fi

# ---------------------------------------------------------------------
# 単発の通知を処理する
# ---------------------------------------------------------------------
if [[ "$has_message" != "true" ]]; then
    printf '[ERROR] --message または --replay のいずれかが必要です。\n' >&2
    usage >&2
    exit 1
fi

# --message - のときは標準入力から本文を読む。
# 案件No.3のログ監視ツールのように複数行の本文を渡す場合、
# コマンドライン引数より標準入力の方が扱いが確実。
if [[ "$opt_message" == "-" ]]; then
    opt_message="$(cat)"
fi

if [[ -z "$opt_host" ]]; then
    opt_host="$(hostname 2>/dev/null || printf 'unknown-host')"
fi
if [[ -z "$opt_source" ]]; then
    opt_source="unknown"
fi

if [[ -n "$opt_at" ]]; then
    if ! event_epoch="$(date -d "$opt_at" +%s 2>/dev/null)"; then
        ar_log ERROR "--at の日時を解釈できません: ${opt_at}"
        exit 1
    fi
    event_ts="$opt_at"
else
    event_epoch="$(ar_now_epoch)"
    event_ts="$(ar_now_str)"
fi

# 通知を1件処理する前に、期限切れの集約ウィンドウを閉じておく。
# cronのflushを待たずに、まとめ通知が適切なタイミングで出るようにするため。
ar_flush_expired "$event_epoch"

ar_handle_event "$event_ts" "$event_epoch" "$opt_source" "$opt_host" "$opt_message"

exit 0
