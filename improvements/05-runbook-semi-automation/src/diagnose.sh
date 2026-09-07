#!/usr/bin/env bash
#
# =====================================================================
# diagnose.sh
# 改善案件No.5: 手順書ベースの障害対応の半自動化 - 一次切り分け自動化
#
# 概要:
#   Webサーバー障害の通知を受けたときに担当者が手打ちしていた
#   「一次切り分けの10コマンド」をまとめて実行し、
#   結果を1画面のサマリにして表示する。
#
#   このスクリプトは読み取り専用である。
#   サービスの起動・停止・再起動、ファイルの削除は一切行わない。
#   「情報を集めて見せる」ところまでが担当範囲で、
#   「直すかどうかの判断」は人に残す(設計方針は 03-design.md 参照)。
#
# 実行方法:
#   ./diagnose.sh                 # 既定の設定ファイルで診断する
#   ./diagnose.sh -s nginx        # 対象サービスを一時的に上書きする
#   ./diagnose.sh -q              # 進捗ログを出さずサマリだけ表示する
#   ./diagnose.sh -N              # ファイルを一切書かずに画面表示のみ
#
# 終了ステータス:
#   0 = 異常なし / 1 = 警告あり / 2 = 異常あり / 3 = 実行エラー
# =====================================================================

set -uo pipefail
# -u : 未定義変数の参照をエラーにする(設定漏れ・タイプミスの早期発見)
# -o pipefail : パイプの途中で失敗したらパイプ全体を失敗扱いにする
# -e は付けない。1つのチェックが失敗しても残りのチェックを最後まで
#     実行し、「集められた情報だけでも人に見せる」ことを優先するため。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # lib/common.sh 側で参照される変数
RB_SCRIPT_NAME="diagnose.sh"
SCRIPT_VERSION="1.0.0"

# 共通関数ライブラリを読み込む
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

# ---------------------------------------------------------------------
# 使い方の表示
# ---------------------------------------------------------------------
usage() {
    cat <<'USAGE'
使い方: diagnose.sh [オプション]

Webサーバー障害の一次切り分け情報をまとめて収集し、サマリを表示する。
このスクリプトは読み取り専用で、復旧操作は一切行わない。

オプション:
  -c, --config <path>   設定ファイルのパス(既定: スクリプトと同じ場所の runbook.conf)
  -s, --service <name>  対象サービス名を上書きする(既定: 設定ファイルの WEB_SERVICE)
  -o, --output <path>   診断レポートの出力先ファイルを指定する
  -q, --quiet           INFOログを画面に出さず、サマリだけを表示する
  -N, --no-save         ファイルを一切書かずに画面表示だけ行う(権限が無い環境向け)
  -h, --help            このヘルプを表示する

終了ステータス:
  0  異常なし
  1  警告あり(すぐ落ちる状態ではないが要注意)
  2  異常あり(対応が必要)
  3  実行エラー(設定不備・前提コマンド不足など)
USAGE
}

# ---------------------------------------------------------------------
# 引数の解析
#   設定ファイルの場所を引数で変えられるようにするため、
#   設定の読み込みより先に引数を解析する。
# ---------------------------------------------------------------------
OPT_CONFIG=""
OPT_SERVICE=""
OPT_OUTPUT=""
NO_SAVE=false

while [ $# -gt 0 ]; do
    case "$1" in
        -c | --config)
            [ $# -ge 2 ] || { echo "[ERROR] --config には値が必要です" >&2; exit 3; }
            OPT_CONFIG="$2"
            shift 2
            ;;
        -s | --service)
            [ $# -ge 2 ] || { echo "[ERROR] --service には値が必要です" >&2; exit 3; }
            OPT_SERVICE="$2"
            shift 2
            ;;
        -o | --output)
            [ $# -ge 2 ] || { echo "[ERROR] --output には値が必要です" >&2; exit 3; }
            OPT_OUTPUT="$2"
            shift 2
            ;;
        -q | --quiet)
            # shellcheck disable=SC2034  # lib/common.sh 側で参照される変数
            RB_QUIET=true
            shift
            ;;
        -N | --no-save)
            NO_SAVE=true
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "[ERROR] 不明なオプションです: $1" >&2
            usage >&2
            exit 3
            ;;
    esac
done

# ---------------------------------------------------------------------
# 設定ファイルの読み込み
#   優先順位: -c で指定 > 環境変数 RUNBOOK_CONFIG > スクリプトと同じ場所
# ---------------------------------------------------------------------
CONFIG_FILE="${OPT_CONFIG:-${RUNBOOK_CONFIG:-${SCRIPT_DIR}/runbook.conf}}"
if [ ! -r "$CONFIG_FILE" ]; then
    echo "[ERROR] 設定ファイルが読めません: ${CONFIG_FILE}" >&2
    exit 3
fi
# shellcheck source=runbook.conf
. "$CONFIG_FILE"

# 引数での上書き(設定ファイルより引数を優先する)
[ -n "$OPT_SERVICE" ] && WEB_SERVICE="$OPT_SERVICE"

# 必須項目が埋まっているか確認する(空のまま進むと原因不明の失敗になるため)
rb_require_config WEB_SERVICE HEALTH_URL AUDIT_LOG DIAG_DIR STATE_DIR \
    || rb_die "設定ファイルの内容を確認してください: ${CONFIG_FILE}"

# ---------------------------------------------------------------------
# 出力先の準備
# ---------------------------------------------------------------------
RUN_ID="$(date '+%Y%m%d-%H%M%S')"
REPORT_FILE=""
FINDINGS_FILE=""

if [ "$NO_SAVE" = "false" ]; then
    mkdir -p "$DIAG_DIR" "$STATE_DIR" 2>/dev/null \
        || rb_die "出力先ディレクトリを作成できません(権限を確認してください): ${DIAG_DIR}"

    REPORT_FILE="${OPT_OUTPUT:-${DIAG_DIR}/diagnosis-${RUN_ID}.log}"
    FINDINGS_FILE="${STATE_DIR}/last-diagnosis.env"

    : > "$REPORT_FILE" 2>/dev/null \
        || rb_die "診断レポートを作成できません: ${REPORT_FILE}"

    # ライブラリのログ関数がこのファイルにも追記するようにする
    # shellcheck disable=SC2034  # lib/common.sh 側で参照される変数
    RB_RUN_LOG="$REPORT_FILE"

    if ! rb_init_audit_log; then
        # 監査ログが無くても診断(読み取り専用)は続行してよい。
        # ただし「記録が残らない状態である」ことは必ず警告する。
        rb_warn "監査ログを利用できません。診断は続行しますが記録は残りません。"
    fi
else
    rb_info "--no-save が指定されたため、ファイルへの出力は行いません。"
fi

# ---------------------------------------------------------------------
# 診断レポート(詳細)への出力用ヘルパー
# ---------------------------------------------------------------------

# report_line: レポートファイルへ1行書く(--no-save のときは何もしない)
report_line() {
    [ -n "$REPORT_FILE" ] || return 0
    printf '%s\n' "$*" >> "$REPORT_FILE"
}

# report_cmd: 実行したコマンドとその生の出力をレポートへ残す
#   なぜ生の出力も残すのか:
#     サマリは「判定結果」だけを見せるので、後から
#     「本当にそうだったのか」を確認できる材料が必要になるため。
report_cmd() {
    local title="$1"
    shift
    [ -n "$REPORT_FILE" ] || return 0
    {
        printf '\n----- %s -----\n' "$title"
        printf '$ %s\n' "$*"
    } >> "$REPORT_FILE"
    # 終了コードは変数に取ってから判定する。
    # if ! コマンド; then ... の中で $? を見ると「!(否定)の結果」が
    # 入ってしまい、常に0になってしまうため。
    local rc=0
    rb_run "$@" >> "$REPORT_FILE" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
        printf '(コマンドが正常終了しませんでした: rc=%s)\n' "$rc" >> "$REPORT_FILE"
    fi
}

# ---------------------------------------------------------------------
# 判定結果を貯めておく入れ物
#   declare -A は連想配列(文字列をキーにできる配列)の宣言。
# ---------------------------------------------------------------------
declare -A CHECK_NAME CHECK_KEY CHECK_STATUS CHECK_DETAIL
CHECK_ORDER=(D1 D2 D3 D4 D5 D6 D7 D8)

# チェック項目の定義(表示名と、結果ファイルに書くときのキー名)
CHECK_NAME[D1]="サービス状態";       CHECK_KEY[D1]="SERVICE"
CHECK_NAME[D2]="リッスンポート";     CHECK_KEY[D2]="PORT"
CHECK_NAME[D3]="HTTP応答";           CHECK_KEY[D3]="HTTP"
CHECK_NAME[D4]="設定ファイル構文";   CHECK_KEY[D4]="CONFIG"
CHECK_NAME[D5]="ディスク使用率";     CHECK_KEY[D5]="DISK"
CHECK_NAME[D6]="メモリ使用率";       CHECK_KEY[D6]="MEMORY"
CHECK_NAME[D7]="ロードアベレージ";   CHECK_KEY[D7]="LOAD"
CHECK_NAME[D8]="直近ログのエラー";   CHECK_KEY[D8]="LOG"

COUNT_OK=0
COUNT_WARN=0
COUNT_NG=0
COUNT_SKIP=0

# add_finding: 1つのチェック結果を記録する
#   引数: チェックID 判定(OK/WARN/NG/SKIP) 詳細メッセージ
add_finding() {
    local id="$1" status="$2"
    shift 2
    CHECK_STATUS[$id]="$status"
    CHECK_DETAIL[$id]="$*"
    case "$status" in
        OK)   COUNT_OK=$((COUNT_OK + 1)) ;;
        WARN) COUNT_WARN=$((COUNT_WARN + 1)) ;;
        NG)   COUNT_NG=$((COUNT_NG + 1)) ;;
        *)    COUNT_SKIP=$((COUNT_SKIP + 1)) ;;
    esac
    rb_info "[${status}] ${id} ${CHECK_NAME[$id]}: $*"
}

# systemd_available: systemd が実際に動いている環境かどうかを判定する
#   /run/systemd/system というディレクトリは systemd が PID 1 として
#   起動しているときにだけ存在する。コンテナや WSL では存在しないため、
#   systemctl コマンドがあっても使えないケースをここで見分けられる。
systemd_available() {
    rb_have_cmd systemctl && [ -d /run/systemd/system ]
}

# =====================================================================
# 一次切り分けの本体
#
# 見る順番には理由がある(03-design.md 4章参照):
#   1. サービス(D1〜D4): 「そもそもサービスが動いて応答しているか」
#      → ここがNGなら、原因が何であれ利用者から見た障害は継続している
#   2. リソース(D5〜D7): 「動けない理由がディスク・メモリ・CPUにないか」
#      → サービス異常の原因になっていることが多い
#   3. ログ(D8): 「何が起きたのか」の手がかり
#      → 上の2つで見えた事実を裏付ける材料
# =====================================================================

# ---- D1: サービス状態 -------------------------------------------------
check_service() {
    local id="D1"
    local state=""

    if systemd_available; then
        report_cmd "サービス状態 (systemctl status ${WEB_SERVICE})" \
            systemctl status "$WEB_SERVICE" --no-pager -n 0
        state="$(rb_run systemctl is-active "$WEB_SERVICE" 2>/dev/null)"
        case "$state" in
            active)
                add_finding "$id" "OK" "${WEB_SERVICE} = active"
                ;;
            "")
                add_finding "$id" "NG" "${WEB_SERVICE} の状態を取得できません(ユニットが存在しない可能性)"
                ;;
            *)
                add_finding "$id" "NG" "${WEB_SERVICE} = ${state}"
                ;;
        esac
        return 0
    fi

    # --- systemd が使えない環境のフォールバック ---
    if rb_have_cmd pgrep; then
        report_cmd "プロセス確認 (pgrep -a ${WEB_PROCESS})" pgrep -a "$WEB_PROCESS"
        if pgrep -x "$WEB_PROCESS" >/dev/null 2>&1; then
            add_finding "$id" "OK" "プロセス ${WEB_PROCESS} は起動中(systemd未使用のため代替確認)"
        else
            add_finding "$id" "NG" "プロセス ${WEB_PROCESS} が見つかりません(systemd未使用のため代替確認)"
        fi
    else
        add_finding "$id" "SKIP" "systemctl も pgrep も使えないため確認できません"
    fi
}

# ---- D2: リッスンポート ----------------------------------------------
check_ports() {
    local id="D2"
    local listen_output="" missing="" port=""

    if rb_have_cmd ss; then
        report_cmd "リッスンポート一覧 (ss -ltnp)" ss -ltnp
        listen_output="$(rb_run ss -H -ltn 2>/dev/null)"
    elif rb_have_cmd netstat; then
        report_cmd "リッスンポート一覧 (netstat -ltn)" netstat -ltn
        listen_output="$(rb_run netstat -ltn 2>/dev/null)"
    else
        add_finding "$id" "SKIP" "ss / netstat のどちらも無いため確認できません"
        return 0
    fi

    for port in $LISTEN_PORTS; do
        # ":80 " または ":80" で終わる列があるかを見る。
        # grep -E の正規表現で「コロン+ポート番号」の直後が
        # 空白か行末であることを確認し、":8080" が ":80" に
        # 誤って一致しないようにしている。
        if ! printf '%s\n' "$listen_output" | grep -Eq "(:|\.)${port}([[:space:]]|$)"; then
            missing="${missing}${port} "
        fi
    done

    if [ -z "$missing" ]; then
        add_finding "$id" "OK" "待ち受け確認 OK (${LISTEN_PORTS})"
    else
        add_finding "$id" "NG" "待ち受けていないポート: ${missing% }"
    fi
}

# ---- D3: HTTP応答 -----------------------------------------------------
check_http() {
    local id="D3"
    local code="" rc=0

    if ! rb_have_cmd curl; then
        add_finding "$id" "SKIP" "curl が無いため確認できません"
        return 0
    fi

    # -o /dev/null : 本文は捨てる(欲しいのはステータスコードだけ)
    # -s           : 進捗表示を出さない
    # -w           : 指定した項目だけを出力する(ここではHTTPコード)
    # --max-time   : 応答が返らないときに待ち続けないための上限
    code="$(rb_run curl -o /dev/null -s -w '%{http_code}' \
        --max-time "$HTTP_TIMEOUT" "$HEALTH_URL" 2>/dev/null)"
    rc=$?
    report_line ""
    report_line "----- HTTP応答 (${HEALTH_URL}) -----"
    report_line "http_code=${code} curl_exit=${rc}"

    if [ "$rc" -ne 0 ]; then
        add_finding "$id" "NG" "${HEALTH_URL} へ接続できません (curl終了コード=${rc})"
        return 0
    fi

    case "$code" in
        2?? | 3??) add_finding "$id" "OK" "${HEALTH_URL} = HTTP ${code}" ;;
        4??)       add_finding "$id" "WARN" "${HEALTH_URL} = HTTP ${code}(サーバーは応答しているが正常な内容ではない)" ;;
        *)         add_finding "$id" "NG" "${HEALTH_URL} = HTTP ${code}" ;;
    esac
}

# ---- D4: 設定ファイルの構文チェック ------------------------------------
check_config_syntax() {
    local id="D4"

    if [ "${#SERVICE_CONFIG_TEST[@]}" -eq 0 ]; then
        add_finding "$id" "SKIP" "SERVICE_CONFIG_TEST が未設定のため確認しません"
        return 0
    fi
    if ! rb_have_cmd "${SERVICE_CONFIG_TEST[0]}"; then
        add_finding "$id" "SKIP" "${SERVICE_CONFIG_TEST[0]} コマンドが無いため確認できません"
        return 0
    fi

    report_cmd "設定ファイル構文チェック" "${SERVICE_CONFIG_TEST[@]}"
    if rb_run_priv "${SERVICE_CONFIG_TEST[@]}" >/dev/null 2>&1; then
        add_finding "$id" "OK" "${SERVICE_CONFIG_TEST[*]} = 構文エラーなし"
    else
        add_finding "$id" "NG" "${SERVICE_CONFIG_TEST[*]} が失敗(構文エラーの可能性。詳細はレポート参照)"
    fi
}

# ---- D5: ディスク使用率 -----------------------------------------------
check_disk() {
    local id="D5"
    local mount="" pct="" worst=0 detail="" status="OK"

    if ! rb_have_cmd df; then
        add_finding "$id" "SKIP" "df が無いため確認できません"
        return 0
    fi

    report_cmd "ディスク使用率 (df -hP)" df -hP

    for mount in $DISK_TARGETS; do
        # -P はPOSIX形式での出力指定。長いデバイス名でも1行に収まるため、
        # awk での列位置がずれない(改行されると $5 が別の値になってしまう)。
        pct="$(df -P "$mount" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')"
        if [ -z "$pct" ]; then
            detail="${detail}${mount}=取得不可 "
            continue
        fi
        detail="${detail}${mount}=${pct}% "
        [ "$pct" -gt "$worst" ] && worst="$pct"
    done

    if [ -z "$detail" ]; then
        add_finding "$id" "SKIP" "対象のマウントポイントを取得できません (${DISK_TARGETS})"
        return 0
    fi

    if [ "$worst" -ge "$DISK_CRIT_PERCENT" ]; then
        status="NG"
    elif [ "$worst" -ge "$DISK_WARN_PERCENT" ]; then
        status="WARN"
    fi
    add_finding "$id" "$status" "${detail% } (警告=${DISK_WARN_PERCENT}% 異常=${DISK_CRIT_PERCENT}%)"
}

# ---- D6: メモリ使用率 -------------------------------------------------
check_memory() {
    local id="D6"
    local total=0 available=0 used_pct=0 status="OK"

    if ! rb_have_cmd free; then
        add_finding "$id" "SKIP" "free が無いため確認できません"
        return 0
    fi

    report_cmd "メモリ使用状況 (free -m)" free -m

    # available列($7)は「今すぐ割り当て可能なメモリ量」。
    # free列($4)ではなく available を見るのは、Linuxがキャッシュとして
    # 使っているメモリは必要になれば解放されるため、free だけを見ると
    # 「メモリが足りない」と誤判定してしまうから。
    read -r total available < <(free -m | awk '/^Mem:/ {avail = ($7 == "") ? $4 : $7; print $2, avail}')

    if [ -z "${total:-}" ] || [ "${total:-0}" -eq 0 ]; then
        add_finding "$id" "SKIP" "メモリ情報を解析できません"
        return 0
    fi

    used_pct=$(( (total - available) * 100 / total ))
    if [ "$used_pct" -ge "$MEM_CRIT_PERCENT" ]; then
        status="NG"
    elif [ "$used_pct" -ge "$MEM_WARN_PERCENT" ]; then
        status="WARN"
    fi
    add_finding "$id" "$status" \
        "使用率=${used_pct}% (全体${total}MB / 利用可能${available}MB, 警告=${MEM_WARN_PERCENT}%)"
}

# ---- D7: ロードアベレージ ---------------------------------------------
check_load() {
    local id="D7"
    local load1="" cores=1 status="OK" ratio=""

    if [ ! -r /proc/loadavg ]; then
        add_finding "$id" "SKIP" "/proc/loadavg が読めないため確認できません"
        return 0
    fi

    report_cmd "ロードアベレージ (/proc/loadavg)" cat /proc/loadavg

    load1="$(awk '{print $1}' /proc/loadavg)"
    if rb_have_cmd nproc; then
        cores="$(nproc)"
    fi
    [ "${cores:-0}" -ge 1 ] || cores=1

    # ロードアベレージは小数なので、整数しか扱えない [ ] ではなく
    # awk で比較する(awk は浮動小数点の計算ができる)。
    ratio="$(awk -v l="$load1" -v c="$cores" 'BEGIN { printf "%.2f", l / c }')"
    if awk -v r="$ratio" -v t="$LOAD_CRIT_PER_CORE" 'BEGIN { exit !(r >= t) }'; then
        status="NG"
    elif awk -v r="$ratio" -v t="$LOAD_WARN_PER_CORE" 'BEGIN { exit !(r >= t) }'; then
        status="WARN"
    fi
    add_finding "$id" "$status" \
        "1分平均=${load1} / ${cores}コア = ${ratio}(警告=${LOAD_WARN_PER_CORE} 異常=${LOAD_CRIT_PER_CORE})"
}

# ---- D8: 直近ログのエラー件数 -----------------------------------------
check_recent_logs() {
    local id="D8"
    local count=0 source_desc="" file="" found_source=false

    if systemd_available && rb_have_cmd journalctl; then
        report_cmd "直近ログ (journalctl -u ${WEB_SERVICE})" \
            journalctl -u "$WEB_SERVICE" --since "${RECENT_ERROR_MINUTES} min ago" \
            --no-pager -n "$LOG_TAIL_LINES"
        # grep -c は該当0件のとき終了コード1を返すため、
        # || true を付けて「0件」を正常な結果として扱う。
        count="$(rb_run journalctl -u "$WEB_SERVICE" --since "${RECENT_ERROR_MINUTES} min ago" \
            --no-pager -q 2>/dev/null | grep -Ec "$ERROR_PATTERN" || true)"
        source_desc="journalctl(直近${RECENT_ERROR_MINUTES}分)"
        found_source=true
    else
        for file in $ERROR_LOG_FILES; do
            [ -r "$file" ] || continue
            found_source=true
            report_cmd "ログ抜粋 (${file})" tail -n "$LOG_TAIL_LINES" "$file"
            local file_count=0
            file_count="$(tail -n "$LOG_SCAN_LINES" "$file" 2>/dev/null | grep -Ec "$ERROR_PATTERN" || true)"
            count=$((count + file_count))
        done
        source_desc="ログファイル末尾${LOG_SCAN_LINES}行"
    fi

    if [ "$found_source" != "true" ]; then
        add_finding "$id" "SKIP" "参照できるログがありません(journalctl も ${ERROR_LOG_FILES} も読めません)"
        return 0
    fi

    if [ "$count" -ge "$ERROR_COUNT_WARN" ]; then
        add_finding "$id" "WARN" "エラー相当のログ ${count}件 / ${source_desc}(警告=${ERROR_COUNT_WARN}件)"
    else
        add_finding "$id" "OK" "エラー相当のログ ${count}件 / ${source_desc}"
    fi
}

# =====================================================================
# メイン処理
# =====================================================================

rb_info "診断を開始します (対象サービス=${WEB_SERVICE}, 設定=${CONFIG_FILE})"

report_line "====================================================================="
report_line " 一次切り分け診断レポート"
report_line " 実行日時 : $(rb_timestamp)"
report_line " ホスト   : ${RB_HOSTNAME}"
report_line " 実行者   : $(rb_actor)"
report_line " 対象     : ${WEB_SERVICE} (${HEALTH_URL})"
report_line " ツール版 : diagnose.sh ${SCRIPT_VERSION} / lib ${RB_LIB_VERSION}"
report_line "====================================================================="

if ! rb_have_cmd timeout; then
    rb_warn "timeout コマンドがありません。応答しないコマンドで処理が止まる可能性があります。"
fi

# サービス → リソース → ログ の順に確認する
check_service
check_ports
check_http
check_config_syntax
check_disk
check_memory
check_load
check_recent_logs

# ---- 総合判定 --------------------------------------------------------
OVERALL="OK"
EXIT_CODE="$RB_EXIT_OK"
NEXT_ACTION="対応不要です。障害通知が誤検知でなかったか、通知元の条件を確認してください。"

if [ "$COUNT_NG" -gt 0 ]; then
    OVERALL="CRITICAL"
    EXIT_CODE="$RB_EXIT_CRIT"
    NEXT_ACTION="recover.sh --dry-run を実行し、復旧候補と実行内容を確認してください。"
elif [ "$COUNT_WARN" -gt 0 ]; then
    OVERALL="WARN"
    EXIT_CODE="$RB_EXIT_WARN"
    NEXT_ACTION="今すぐの復旧操作は不要な可能性が高いです。詳細レポートで傾向を確認してください。"
fi

# ---- 画面へのサマリ出力(標準出力) -----------------------------------
{
    printf '=====================================================================\n'
    printf ' 一次切り分け診断サマリ  host=%s  %s\n' "$RB_HOSTNAME" "$(rb_timestamp)"
    printf ' 対象: %s (%s)\n' "$WEB_SERVICE" "$HEALTH_URL"
    printf '=====================================================================\n'
    for id in "${CHECK_ORDER[@]}"; do
        printf ' [%-4s] %s %s: %s\n' \
            "${CHECK_STATUS[$id]:-SKIP}" "$id" "${CHECK_NAME[$id]}" "${CHECK_DETAIL[$id]:-未実施}"
    done
    # printf の書式文字列が "-" で始まるとオプションと解釈されてしまうため、
    # 区切り線は %s を使って値として渡す。
    printf '%s\n' '---------------------------------------------------------------------'
    printf ' 総合判定 : %s (NG=%d WARN=%d OK=%d SKIP=%d)\n' \
        "$OVERALL" "$COUNT_NG" "$COUNT_WARN" "$COUNT_OK" "$COUNT_SKIP"
    printf ' 所要時間 : %d秒\n' "$SECONDS"
    if [ -n "$REPORT_FILE" ]; then
        printf ' 詳細     : %s\n' "$REPORT_FILE"
    else
        printf ' 詳細     : (--no-save のため保存していません)\n'
    fi
    printf ' 次の一手 : %s\n' "$NEXT_ACTION"
    printf '=====================================================================\n'
} | tee -a "${REPORT_FILE:-/dev/null}"

# ---- 診断結果ファイルの書き出し(recover.sh が読む) --------------------
if [ -n "$FINDINGS_FILE" ]; then
    # 一時ファイルに書いてから mv で置き換える。
    # 書き込み途中のファイルを recover.sh が読んでしまう事故を防ぐため
    # (mv は同じファイルシステム内なら「一瞬で入れ替わる」操作)。
    TMP_FINDINGS="${FINDINGS_FILE}.tmp.$$"
    {
        printf '# diagnose.sh が自動生成したファイル。手で編集しない。\n'
        printf 'DIAG_TIMESTAMP=%s\n' "$(rb_timestamp_iso)"
        printf 'DIAG_HOST=%s\n' "$RB_HOSTNAME"
        printf 'DIAG_SERVICE=%s\n' "$WEB_SERVICE"
        printf 'DIAG_OVERALL=%s\n' "$OVERALL"
        for id in "${CHECK_ORDER[@]}"; do
            printf 'DIAG_%s_STATUS=%s\n' "${CHECK_KEY[$id]}" "${CHECK_STATUS[$id]:-SKIP}"
        done
        printf 'DIAG_REPORT_FILE=%s\n' "$REPORT_FILE"
    } > "$TMP_FINDINGS" 2>/dev/null && mv -f "$TMP_FINDINGS" "$FINDINGS_FILE" 2>/dev/null

    if [ -f "$FINDINGS_FILE" ]; then
        rb_info "診断結果を保存しました: ${FINDINGS_FILE}"
    else
        rb_warn "診断結果ファイルを保存できませんでした: ${FINDINGS_FILE}"
        rm -f "$TMP_FINDINGS" 2>/dev/null || true
    fi
fi

# ---- 監査ログ ---------------------------------------------------------
# 診断は読み取り専用だが、「いつ誰が状況を確認したか」も追跡できるように
# 記録する。障害対応の時系列を後から再現するために必要な情報になる。
rb_audit "diagnose" "-" "$WEB_SERVICE" "$OVERALL" "$EXIT_CODE" \
    "NG=${COUNT_NG} WARN=${COUNT_WARN} OK=${COUNT_OK} SKIP=${COUNT_SKIP} report=${REPORT_FILE:-none}" \
    || rb_warn "監査ログを記録できませんでした(診断結果自体は上記の通りです)"

rb_info "診断を終了します (終了コード=${EXIT_CODE})"
exit "$EXIT_CODE"
