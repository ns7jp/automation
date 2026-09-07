#!/usr/bin/env bash
#
# =====================================================================
# health_check.sh(改善版 / After)
# 改善案件No.2: 共通ライブラリ opslib.sh を使うように書き換えたもの
#
# 元ファイル: projects/04-server-health-check/src/health_check.sh
#   元ファイルは「改善前(Before)の証拠」としてそのまま残してあるため、
#   このファイルと見比べれば、どこがどう変わったのかが分かる。
#
# 変わったところ(3か所だけ):
#   1. 設定ファイルの読み込み    -> ops_load_config に置き換え
#   2. log() 関数の定義          -> 削除し、ops_log_info / _warn / _error を使用
#   3. notify_slack() 関数の定義 -> 削除し、ops_notify_slack を使用
#
# 特に重要な変更:
#   旧 notify_slack() は Slack へ送るJSONを
#       --data "{\"text\": \"${message}\"}"
#   と文字列連結で組み立てていた。監視対象名やURLに " や \ が
#   含まれると壊れたJSONになり、通知が届かない潜在バグがあった。
#   ops_notify_slack は jq でエスケープするため、この問題は起きない。
#
# 変わっていないところ:
#   ・health_check.conf / targets.conf の書式(後方互換)
#   ・ping / curl による死活監視、連続失敗回数による通知抑制、
#     稼働率の集計、Markdownレポート生成といった本来の処理内容
#   ・cron から呼ばれる際の実行方法と終了ステータスの意味
#
# 実行方法:
#   sudo /opt/server-health-check/health_check.sh
#
# 前提:
#   同じディレクトリに health_check.conf、targets.conf、opslib.sh が
#   配置されていること。
# =====================================================================

set -u
# -u : 未定義の変数を参照した場合にエラーで停止する(タイプミスの早期発見)。
# 案件No.2(バックアップ自動化)と同じ方針で、あえて -e は付けていない。
# 1台のサーバーへの疎通確認が失敗しても、そこでスクリプト全体を止めず、
# 「残りのサーバーのチェック」「レポート生成」まで必ず実行させたいため、
# 各コマンドの終了コード(戻り値)を自前でチェックしてハンドリングする。

# ----------------------------------------------------------------
# 共通ライブラリの読み込み
#
# ${BASH_SOURCE[0]} は「このファイル自身のパス」を常に指す。
# $0 は起動のされ方によって変わるため、スクリプトの置き場所を基準に
# 相対パスを組み立てたいときは ${BASH_SOURCE[0]} を使うのが確実。
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
# 旧実装では「存在チェック -> エラー出力 -> exit -> source」を
# 自前で14行書いていた。ops_load_config が同じ役割を果たし、
# さらに読み取り権限と権限の緩さまで確認してくれる。
#
# 注意: health_check.conf の中で TARGETS_FILE="${SCRIPT_DIR}/targets.conf"
# のように、呼び出し側の変数 SCRIPT_DIR を参照している。
# これは「設定ファイルが呼び出し側の変数に暗黙に依存している」状態で、
# 本来は避けたい書き方である(SCRIPT_DIR の定義を消したり名前を変えると、
# 一見無関係な設定ファイルが壊れる)。ただし今回は後方互換を優先し、
# 既存の設定ファイルをそのまま使えるようにしている。
# 改善は 05-effect-measurement.md の「残課題」に記載した。
# ----------------------------------------------------------------
CONFIG_FILE="${SCRIPT_DIR}/health_check.conf"

if ! ops_load_config "$CONFIG_FILE"; then
    exit 1
fi

if [ ! -f "$TARGETS_FILE" ]; then
    ops_log_error "監視対象リストが見つかりません: ${TARGETS_FILE}"
    exit 1
fi

# ----------------------------------------------------------------
# 設定値をライブラリへ引き渡す(後方互換のための橋渡し)
#
# health_check.conf は改善前から LOG_FILE / ENABLE_SLACK_NOTIFY /
# SLACK_WEBHOOK_URL という名前で値を持っている。
# 運用中の設定ファイルを書き換えずに移行できるよう、ここで
# ライブラリが使う OPS_* 変数へ移し替えるだけにしている。
# ----------------------------------------------------------------
if ! ops_log_init "$LOG_FILE"; then
    exit 1
fi

# 以下2つの変数は opslib.sh の ops_notify_slack が参照する。
# ただし解析ツールは既定では source 先(opslib.sh)まで読まないため、
# 「代入しただけで使っていない変数」だと誤検知される(SC2034)。
# 実際には使われているので、その行だけ警告を抑止する。
# shellcheck disable=SC2034
OPS_SLACK_ENABLED="$ENABLE_SLACK_NOTIFY"
# shellcheck disable=SC2034
OPS_SLACK_WEBHOOK_URL="$SLACK_WEBHOOK_URL"

# ----------------------------------------------------------------
# このスクリプト固有の関数(共通化の対象外)
#
# なぜ共通ライブラリに入れないのか:
#   check_ping / check_http / calc_uptime は「サーバー死活監視」という
#   この案件だけの関心事であり、他の3スクリプトでは一度も使われていない。
#   使われる見込みのない処理までライブラリに入れると、ライブラリが
#   肥大化して読みづらくなり、変更の影響範囲も無駄に広がる。
#   「2か所以上で実際に重複しているものだけを共通化する」という
#   判断基準にしている(詳細は 03-design.md)。
# ----------------------------------------------------------------

# check_ping: ICMP ping による死活監視
#   引数1: IPアドレスまたはホスト名
#   戻り値: 0=応答あり(生存とみなす) / 0以外=応答なし
check_ping() {
    local target="$1"

    # -c <回数> : パケットを送信する回数(count)。
    #             1回だけ送って応答が無くても、それは「サーバーが
    #             落ちている」のか「たまたま1パケットだけ経路上で
    #             ロストした(瞬間的な揺らぎ)」のか区別できない。
    #             複数回(PING_COUNT)送ることで、その揺らぎに
    #             よる誤判定を減らしている。
    # -W <秒>   : 応答を待つタイムアウト秒数。応答が遅いだけの
    #             サーバーを、待たずに即NG扱いにしないための猶予時間
    #             (Ubuntu標準のiputils-pingでは秒単位で指定する)。
    # 標準出力・標準エラー出力は捨てる(このスクリプトが使うのは
    # 「pingコマンドが成功したか失敗したか」という終了コードのみ)。
    ping -c "${PING_COUNT}" -W "${PING_TIMEOUT}" "$target" > /dev/null 2>&1
}

# check_http: HTTPステータスコードによる死活監視
#   引数1: URL
#   引数2: 正常とみなすHTTPステータスコード(例: 200)
#   戻り値: 0=期待したステータスコードが返った / 1=それ以外・接続失敗
check_http() {
    local url="$1"
    local expected_code="$2"
    local actual_code

    # -o /dev/null      : レスポンスボディ(HTMLなど)は判定に使わないので捨てる
    # -s                : silent。進捗バーやエラーメッセージを画面に出さない
    # -w '%{http_code}' : レスポンスの中からHTTPステータスコードだけを
    #                     文字列として出力させる(-oで本文を捨てているので
    #                     標準出力にはこのステータスコードだけが残る)
    # --max-time <秒>   : 応答が無い場合に無限に待ち続けないためのタイムアウト
    # 接続自体に失敗した場合(サーバーがダウンしている等)actual_codeは
    # 空文字になるため、expected_codeとの比較で自動的に不一致=NGとなる。
    actual_code="$(curl -o /dev/null -s -w '%{http_code}' --max-time "${HTTP_TIMEOUT}" "$url")"

    if [ "$actual_code" = "$expected_code" ]; then
        return 0
    else
        return 1
    fi
}

# calc_uptime: 直近UPTIME_WINDOW_HOURS時間における成功率(%)を算出する
#   引数1: サーバー名
#   出力: "97.9" のような数値の文字列、対象データが無ければ "N/A"
calc_uptime() {
    local name="$1"
    local since total ok

    # date -d "-24 hours" : 現在時刻から指定時間だけ遡った日時を計算する
    since="$(date -d "-${UPTIME_WINDOW_HOURS} hours" '+%Y-%m-%d %H:%M:%S')"

    # history.csv の1列目(timestamp)は "YYYY-MM-DD HH:MM:SS" 形式。
    # この形式は年→月→日→時→分→秒の順に並ぶため、文字列としてそのまま
    # 比較しても時系列の前後関係と一致する(辞書式比較=時系列比較になる)。
    # そのため $1 >= since という単純な文字列比較だけで
    # 「直近N時間以内のレコードかどうか」を判定できる。
    total="$(awk -F',' -v name="$name" -v since="$since" \
        '$2 == name && $1 >= since { c++ } END { print c + 0 }' "$HISTORY_FILE")"
    ok="$(awk -F',' -v name="$name" -v since="$since" \
        '$2 == name && $1 >= since && $5 == "OK" { c++ } END { print c + 0 }' "$HISTORY_FILE")"

    if [ "$total" -eq 0 ]; then
        echo "N/A"
    else
        awk -v ok="$ok" -v total="$total" 'BEGIN { printf "%.1f", (ok / total) * 100 }'
    fi
}

# ----------------------------------------------------------------
# 事前準備(各ディレクトリ・ファイルの初期化)
# ----------------------------------------------------------------
mkdir -p "$(dirname "${LOG_FILE}")"
mkdir -p "$(dirname "${STATE_FILE}")"
mkdir -p "$(dirname "${HISTORY_FILE}")"
mkdir -p "$(dirname "${REPORT_FILE}")"

# history.csv がまだ無ければヘッダー行付きで新規作成する
[ -f "$HISTORY_FILE" ] || echo "timestamp,name,type,target,status" > "$HISTORY_FILE"

ops_log_info "===== サーバー死活監視を開始します ====="

# ----------------------------------------------------------------
# 前回までの状態(連続失敗回数・通知済みフラグ)を読み込む
# ----------------------------------------------------------------
# state.csv の書式: name,status,consecutive_fail,notified
#   notified: そのサーバーについて「異常を通知済みかどうか」(yes/no)。
#             これを覚えておくことで、
#             ・閾値を超えた直後の1回だけ通知する(5分ごとに連発しない)
#             ・OKに戻ったときだけ「復旧しました」通知を送る
#             という制御ができる。
declare -A PREV_FAIL_COUNT
declare -A PREV_NOTIFIED

if [ -f "$STATE_FILE" ]; then
    while IFS=',' read -r s_name _ s_fail s_notified; do
        [ -z "$s_name" ] && continue
        PREV_FAIL_COUNT["$s_name"]="$s_fail"
        PREV_NOTIFIED["$s_name"]="$s_notified"
    done < "$STATE_FILE"
fi

# mktemp: 一時ファイルを安全に作成する(他プロセスとファイル名が
# 衝突しないよう、ランダムな名前で作られる)。
# 全サーバーの処理が終わってから最後にまとめて本物のSTATE_FILEへ
# mvすることで、処理途中でスクリプトが中断しても、中途半端な
# 内容でstate.csvが上書きされてしまう事故を防いでいる。
NEW_STATE_FILE="$(mktemp)"

TARGET_COUNT=0
NG_COUNT=0
declare -A REPORT_TYPE
declare -A REPORT_TARGET
declare -A REPORT_STATUS
declare -A REPORT_FAIL_COUNT
TARGET_ORDER=()

# ----------------------------------------------------------------
# 監視対象を1件ずつチェックする
# ----------------------------------------------------------------
while IFS=',' read -r name type target option; do
    # "#"で始まる行(コメント)と空行はスキップする
    [[ -z "$name" || "$name" == \#* ]] && continue

    TARGET_COUNT=$((TARGET_COUNT + 1))
    TARGET_ORDER+=("$name")

    case "$type" in
        ping)
            if check_ping "$target"; then
                result="OK"
            else
                result="NG"
            fi
            ;;
        http)
            if check_http "$target" "$option"; then
                result="OK"
            else
                result="NG"
            fi
            ;;
        *)
            ops_log_error "${name}: 未知の監視方法です(type=${type})。この行はスキップします"
            continue
            ;;
    esac

    prev_fail="${PREV_FAIL_COUNT[$name]:-0}"
    prev_notified="${PREV_NOTIFIED[$name]:-no}"

    if [ "$result" = "OK" ]; then
        # 1回でも成功すれば、連続失敗のカウントはリセットする
        fail_count=0
    else
        fail_count=$((prev_fail + 1))
    fi

    # ----------------------------------------------------------
    # 閾値判定と通知(フラッピング対策の核心部分)
    # ----------------------------------------------------------
    # ・fail_countがFAIL_THRESHOLD未満のうちは、まだ「様子見」の
    #   状態として扱い、通知は送らない(1回失敗しただけの誤検知対策)。
    # ・fail_countがFAIL_THRESHOLD以上になり、かつまだ通知していない
    #   (prev_notified != yes)場合だけ、そのタイミングで1回だけ通知する。
    # ・OKに戻り、かつ直前まで通知中だった場合は「復旧しました」を通知する。
    notified="$prev_notified"

    if [ "$fail_count" -ge "$FAIL_THRESHOLD" ] && [ "$prev_notified" != "yes" ]; then
        ops_log_error "${name}(${target})が${fail_count}回連続でNGです。閾値(${FAIL_THRESHOLD}回)を超えたため異常として通知します"
        ops_notify_slack ":red_circle: [障害検知] ${name}(${target})が${fail_count}回連続でNGです"
        notified="yes"
    elif [ "$result" = "OK" ] && [ "$prev_notified" = "yes" ]; then
        ops_log_info "${name}(${target})が復旧しました"
        ops_notify_slack ":white_check_mark: [復旧] ${name}(${target})が復旧しました"
        notified="no"
    elif [ "$result" = "NG" ]; then
        ops_log_warn "${name}(${target})がNGです(連続${fail_count}回目。通知の閾値は${FAIL_THRESHOLD}回)"
    else
        ops_log_info "${name}(${target})は正常です"
    fi

    [ "$result" = "NG" ] && NG_COUNT=$((NG_COUNT + 1))

    # 更新後の状態を一時ファイルに書き出す(全件処理後にstate.csvへ反映)
    echo "${name},${result},${fail_count},${notified}" >> "$NEW_STATE_FILE"

    # 今回のチェック結果を履歴に1行追記する(稼働率集計・レポートの元データ)
    echo "$(date '+%Y-%m-%d %H:%M:%S'),${name},${type},${target},${result}" >> "$HISTORY_FILE"

    REPORT_TYPE["$name"]="$type"
    REPORT_TARGET["$name"]="$target"
    REPORT_STATUS["$name"]="$result"
    REPORT_FAIL_COUNT["$name"]="$fail_count"

done < "$TARGETS_FILE"

# 一時ファイルの内容を本物のstate.csvへ反映する
mv "$NEW_STATE_FILE" "$STATE_FILE"

ops_log_info "監視完了: 対象${TARGET_COUNT}台中、NG ${NG_COUNT}台"

# ----------------------------------------------------------------
# Markdownレポートの生成(ヒアドキュメント)
# ----------------------------------------------------------------
NOW="$(date '+%Y-%m-%d %H:%M:%S')"

# ヒアドキュメント(<<EOF 〜 EOF)を使うと、複数行の文字列を
# echoを何度も書かずにまとめて出力できる。
# "cat > file <<EOF" は「新規作成(上書き)」、"cat >> file <<EOF" は「追記」。
cat > "$REPORT_FILE" <<EOF
# サーバー死活監視レポート

- 生成日時: ${NOW}
- 監視対象数: ${TARGET_COUNT}台
- 異常判定中: ${NG_COUNT}台
- 連続失敗の通知閾値: ${FAIL_THRESHOLD}回

## 現在の状態一覧

| サーバー名 | 監視方法 | 監視対象 | 状態 | 連続失敗回数 | 直近${UPTIME_WINDOW_HOURS}時間稼働率 |
|---|---|---|---|---|---|
EOF

for name in "${TARGET_ORDER[@]}"; do
    status="${REPORT_STATUS[$name]}"
    fail="${REPORT_FAIL_COUNT[$name]}"

    if [ "$status" = "OK" ]; then
        icon="🟢 OK"
    elif [ "$fail" -ge "$FAIL_THRESHOLD" ]; then
        icon="🔴 異常"
    else
        icon="🟡 経過観察"
    fi

    uptime_value="$(calc_uptime "$name")"
    if [ "$uptime_value" = "N/A" ]; then
        uptime_display="N/A"
    else
        uptime_display="${uptime_value}%"
    fi

    # 表の1行分を追記する(">>"で末尾に追加していく)
    echo "| ${name} | ${REPORT_TYPE[$name]} | ${REPORT_TARGET[$name]} | ${icon} | ${fail}回 | ${uptime_display} |" >> "$REPORT_FILE"
done

cat >> "$REPORT_FILE" <<EOF

## 状態アイコンの見方

| アイコン | 意味 |
|---|---|
| 🟢 OK | 直近のチェックが成功している |
| 🟡 経過観察 | 失敗はしているが、まだ通知の閾値(${FAIL_THRESHOLD}回)未満。誤検知の可能性を考慮しまだ通知はしていない |
| 🔴 異常 | 連続失敗回数が閾値以上に達し、Slackへ異常通知を送信済み |

このレポートは health_check.sh が実行されるたび(既定は5分ごと)に自動的に上書き生成される。
EOF

ops_log_info "レポートを生成しました: ${REPORT_FILE}"
ops_log_info "===== サーバー死活監視を終了します ====="

exit 0
