#!/usr/bin/env bash
#
# =====================================================================
# recover.sh
# 改善案件No.5: 手順書ベースの障害対応の半自動化 - 復旧の半自動化
#
# 概要:
#   diagnose.sh が残した診断結果をもとに、状況に合った復旧手順の
#   「候補」を提示する。実行するかどうかを決めるのは人であり、
#   このスクリプトが勝手に復旧操作を始めることはない。
#
#   自動化しているのは次の3つだけ:
#     1. 状況に応じた復旧候補の提示
#     2. 実行前の前提チェック(危ない状態では実行させない)
#     3. コマンドの実行と、その結果の記録
#   「実行してよいかどうかの判断」は必ず人が行う。
#   (なぜ全自動にしないのかは 02-improvement-proposal.md 5章を参照)
#
# 実行方法:
#   ./recover.sh --dry-run        # 何をするつもりかだけ表示(実行しない)
#   ./recover.sh                  # 候補を提示し、人が選んで承認して実行
#   ./recover.sh -a A2            # アクションを直接指定して実行
#   ./recover.sh --list           # 実行できるアクションの一覧を表示
#
# 終了ステータス:
#   0 = 正常終了(実行成功 / dry-run / 対応不要)
#   2 = 復旧操作を行ったが、復旧を確認できなかった(エスカレーション)
#   3 = 実行エラー(設定不備・前提条件を満たさない・権限不足など)
#   4 = 人が承認しなかった / 非対話環境のため実行しなかった
# =====================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034  # lib/common.sh 側で参照される変数
RB_SCRIPT_NAME="recover.sh"
SCRIPT_VERSION="1.0.0"

# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

# ---------------------------------------------------------------------
# 使い方の表示
# ---------------------------------------------------------------------
usage() {
    cat <<'USAGE'
使い方: recover.sh [オプション]

diagnose.sh の診断結果に応じた復旧手順の候補を提示し、
人の承認を得てから実行する「半自動」の復旧支援ツール。

オプション:
  -n, --dry-run         実行せず、何をするつもりかだけ表示する
  -a, --action <ID>     実行するアクションを直接指定する(例: A2)
  -l, --list            実行できるアクションの一覧を表示する
  -c, --config <path>   設定ファイルのパス(既定: スクリプトと同じ場所の runbook.conf)
  -s, --service <name>  対象サービス名を上書きする
  -q, --quiet           INFOログを画面に出さない
  -h, --help            このヘルプを表示する

安全のための仕様:
  * 危険度が medium 以上の操作は、必ず確認プロンプトで承認を取る
  * 承認の入力待ちには制限時間があり、時間切れは「実行しない」として扱う
  * 端末の無い環境(cron・CI など)では、--dry-run 以外は実行を拒否する
  * 監査ログに書き込めない場合は、復旧操作を実行しない
  * reload / restart の前に設定ファイルの構文チェックを行い、失敗したら中止する
  * ファイルやデータの削除は、このスクリプトでは一切行わない
USAGE
}

# ---------------------------------------------------------------------
# 引数の解析
# ---------------------------------------------------------------------
OPT_CONFIG=""
OPT_SERVICE=""
OPT_ACTION=""
DRY_RUN=false
LIST_ONLY=false

while [ $# -gt 0 ]; do
    case "$1" in
        -n | --dry-run)
            DRY_RUN=true
            shift
            ;;
        -a | --action)
            [ $# -ge 2 ] || { echo "[ERROR] --action には値が必要です" >&2; exit 3; }
            OPT_ACTION="$2"
            shift 2
            ;;
        -l | --list)
            LIST_ONLY=true
            shift
            ;;
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
        -q | --quiet)
            # shellcheck disable=SC2034  # lib/common.sh 側で参照される変数
            RB_QUIET=true
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
# 設定の読み込み
# ---------------------------------------------------------------------
CONFIG_FILE="${OPT_CONFIG:-${RUNBOOK_CONFIG:-${SCRIPT_DIR}/runbook.conf}}"
if [ ! -r "$CONFIG_FILE" ]; then
    echo "[ERROR] 設定ファイルが読めません: ${CONFIG_FILE}" >&2
    exit 3
fi
# shellcheck source=runbook.conf
. "$CONFIG_FILE"

[ -n "$OPT_SERVICE" ] && WEB_SERVICE="$OPT_SERVICE"

rb_require_config WEB_SERVICE HEALTH_URL AUDIT_LOG STATE_DIR ALLOWED_ACTIONS \
    || rb_die "設定ファイルの内容を確認してください: ${CONFIG_FILE}"

FINDINGS_FILE="${STATE_DIR}/last-diagnosis.env"

# ---------------------------------------------------------------------
# アクションの定義表
#
#   ID   : コマンドラインで指定する識別子
#   NAME : 画面に表示する名前
#   RISK : low(読み取りのみ) / medium(影響は限定的) / high(瞬断あり)
#   DESC : 何が起きるかの説明(人が承認を判断するための材料)
#
# ここに無い操作は実行できない。特に「ファイルの削除」「サーバーの再起動」は
# 意図的に定義していない(自動化の対象外。判断も実行も人が行う)。
# ---------------------------------------------------------------------
declare -A ACTION_NAME ACTION_RISK ACTION_DESC
ACTION_IDS=(A1 A2 A3 A4)

ACTION_NAME[A1]="設定ファイルの構文チェック"
ACTION_RISK[A1]="low"
ACTION_DESC[A1]="設定ファイルを読み込んで文法エラーが無いか確認するだけ。サービスには影響しない。"

ACTION_NAME[A2]="サービスへの設定リロード"
ACTION_RISK[A2]="medium"
ACTION_DESC[A2]="サービスに設定を読み直させる。処理中の接続は維持されるため、通常は無停止で反映できる。"

ACTION_NAME[A3]="サービスの再起動"
ACTION_RISK[A3]="high"
ACTION_DESC[A3]="サービスを停止してから起動し直す。数秒間、利用者からのアクセスが失敗する。"

ACTION_NAME[A4]="ログの強制ローテート"
ACTION_RISK[A4]="medium"
ACTION_DESC[A4]="logrotate でログを切り替え、古いログを圧縮する。ログの削除は行わない(削除設定は logrotate 側の定義に従う)。"

# action_command: 実行予定のコマンドを「文字列」で返す(表示・記録用)
action_command() {
    case "$1" in
        A1) printf '%s' "${SERVICE_CONFIG_TEST[*]:-(未設定)}" ;;
        A2) printf 'systemctl reload %s' "$WEB_SERVICE" ;;
        A3) printf 'systemctl restart %s' "$WEB_SERVICE" ;;
        A4) printf 'logrotate --force %s' "$LOGROTATE_CONF" ;;
        *)  printf '(未定義)' ;;
    esac
}

# action_execute: 実際にコマンドを実行する
#   rb_run_priv 経由で実行するため、必ずタイムアウトが付き、
#   一般ユーザーの場合は sudo -n(パスワードを聞かない)で実行される。
action_execute() {
    case "$1" in
        A1) rb_run_priv "${SERVICE_CONFIG_TEST[@]}" ;;
        A2) rb_run_priv systemctl reload "$WEB_SERVICE" ;;
        A3) rb_run_priv systemctl restart "$WEB_SERVICE" ;;
        A4) rb_run_priv logrotate --force "$LOGROTATE_CONF" ;;
        *)  return 3 ;;
    esac
}

# systemd_available: systemd が実際に動いているか(diagnose.sh と同じ判定)
systemd_available() {
    rb_have_cmd systemctl && [ -d /run/systemd/system ]
}

# is_allowed_action: 設定ファイルの許可リストに含まれているか
is_allowed_action() {
    local id="$1" allowed=""
    for allowed in $ALLOWED_ACTIONS; do
        [ "$allowed" = "$id" ] && return 0
    done
    return 1
}

# is_known_action: 定義表に存在するIDか
is_known_action() {
    local id="$1" known=""
    for known in "${ACTION_IDS[@]}"; do
        [ "$known" = "$id" ] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------
# アクション一覧の表示(--list)
# ---------------------------------------------------------------------
print_action_list() {
    printf '=====================================================================\n'
    printf ' 実行できる復旧アクション一覧 (対象サービス: %s)\n' "$WEB_SERVICE"
    printf '=====================================================================\n'
    local id="" mark=""
    for id in "${ACTION_IDS[@]}"; do
        if is_allowed_action "$id"; then
            mark="許可"
        else
            mark="禁止(設定ファイルの ALLOWED_ACTIONS で無効化)"
        fi
        printf '\n %s %s [危険度: %s / %s]\n' "$id" "${ACTION_NAME[$id]}" "${ACTION_RISK[$id]}" "$mark"
        printf '    内容    : %s\n' "${ACTION_DESC[$id]}"
        printf '    コマンド: %s\n' "$(action_command "$id")"
    done
    cat <<'NOTE'

---------------------------------------------------------------------
このツールで「あえて自動化していない」操作
---------------------------------------------------------------------
  * ファイルの削除によるディスク空き容量の確保
      → 何を消してよいかは、そのファイルの中身と業務上の意味を
        知っている人にしか判断できないため、必ず手作業で行う。
  * サーバー本体の再起動
      → 影響範囲が大きすぎるため、責任者の承認を得たうえで手作業で行う。
  * DBやアプリケーションのデータ操作
      → 復旧ではなく変更にあたるため、このツールの対象外とする。
NOTE
}

# ---------------------------------------------------------------------
# 復旧候補の提示
#   diagnose.sh が残した診断結果(KEY=VALUE形式)を読み、
#   状況に合った候補を並べる。ここで決めるのは「候補」までで、
#   実行するかどうかは人が選ぶ。
# ---------------------------------------------------------------------
CANDIDATES=()
CANDIDATE_REASON=()

add_candidate() {
    local id="$1"
    shift
    # 許可されていないアクションは候補にも出さない
    is_allowed_action "$id" || return 0
    # 同じアクションを二重に候補へ入れない
    # (配列が空のときに "${配列[@]}" を参照するとエラーになる環境があるため、
    #  先に要素数を確認してからループする)
    local existing=""
    if [ "${#CANDIDATES[@]}" -gt 0 ]; then
        for existing in "${CANDIDATES[@]}"; do
            [ "$existing" = "$id" ] && return 0
        done
    fi
    CANDIDATES+=("$id")
    CANDIDATE_REASON+=("$*")
}

build_candidates() {
    local svc="" http="" conf="" disk="" overall="" ts=""

    if [ ! -r "$FINDINGS_FILE" ]; then
        rb_warn "診断結果が見つかりません: ${FINDINGS_FILE}"
        rb_warn "先に diagnose.sh を実行してください(候補は提示できません)。"
        return 1
    fi

    ts="$(rb_read_finding DIAG_TIMESTAMP "$FINDINGS_FILE" || true)"
    overall="$(rb_read_finding DIAG_OVERALL "$FINDINGS_FILE" || true)"
    svc="$(rb_read_finding DIAG_SERVICE_STATUS "$FINDINGS_FILE" || true)"
    http="$(rb_read_finding DIAG_HTTP_STATUS "$FINDINGS_FILE" || true)"
    conf="$(rb_read_finding DIAG_CONFIG_STATUS "$FINDINGS_FILE" || true)"
    disk="$(rb_read_finding DIAG_DISK_STATUS "$FINDINGS_FILE" || true)"

    printf '=====================================================================\n'
    printf ' 直近の診断結果  (%s / 総合判定: %s)\n' "${ts:-不明}" "${overall:-不明}"
    printf '   サービス=%s  HTTP=%s  設定構文=%s  ディスク=%s\n' \
        "${svc:-?}" "${http:-?}" "${conf:-?}" "${disk:-?}"
    printf '=====================================================================\n'

    # --- 候補を組み立てる ---
    if [ "$conf" = "NG" ]; then
        add_candidate A1 "設定ファイルに構文エラーの疑い。まず内容を確認する(修正は人が手作業で行う)"
    fi
    if [ "$svc" = "NG" ]; then
        add_candidate A1 "再起動の前に、設定ファイルが正しいことを確認する"
        add_candidate A3 "サービスが停止しているため、再起動で復旧する可能性が高い"
    elif [ "$http" = "NG" ] || [ "$http" = "WARN" ]; then
        add_candidate A1 "リロードの前に、設定ファイルが正しいことを確認する"
        add_candidate A2 "プロセスは生きているが応答しないため、まず影響の小さいリロードを試す"
        add_candidate A3 "リロードで復旧しない場合の次の手段(瞬断あり)"
    fi
    if [ "$disk" = "NG" ] || [ "$disk" = "WARN" ]; then
        add_candidate A4 "ディスク使用率が高いため、ログの強制ローテートで空き容量を確保できる可能性がある"
    fi

    if [ "${#CANDIDATES[@]}" -eq 0 ]; then
        printf '\n復旧操作の候補はありません(診断上、対応が必要な異常は検出されていません)。\n'
        printf '通知が来ているのに異常が無い場合は、監視側の閾値や誤検知を疑ってください。\n'
        return 1
    fi

    printf '\n--- 復旧候補(上から順に試すことを推奨) ---\n'
    local i=0
    for i in "${!CANDIDATES[@]}"; do
        printf '\n [%d] %s %s [危険度: %s]\n' \
            "$((i + 1))" "${CANDIDATES[$i]}" "${ACTION_NAME[${CANDIDATES[$i]}]}" \
            "${ACTION_RISK[${CANDIDATES[$i]}]}"
        printf '     理由    : %s\n' "${CANDIDATE_REASON[$i]}"
        printf '     コマンド: %s\n' "$(action_command "${CANDIDATES[$i]}")"
    done

    if [ "$disk" = "NG" ]; then
        printf '\n [!] ディスク使用率が異常値です。ログのローテートで足りない場合、\n'
        printf '     不要ファイルの削除は「人が中身を確認してから手作業で」行ってください。\n'
        printf '     このツールは削除操作を行いません。\n'
    fi
    return 0
}

# ---------------------------------------------------------------------
# 実行前チェック(前提条件を満たさなければ実行しない)
#
#   ここが「安全側に倒す」設計の要。
#   特に A2/A3 の前に設定ファイルの構文チェックを必ず通す。
#   壊れた設定のまま reload / restart すると、
#   「動いていたプロセスすら起動しなくなる」という二次障害になるため。
# ---------------------------------------------------------------------
preflight() {
    local id="$1"

    case "$id" in
        A1)
            if [ "${#SERVICE_CONFIG_TEST[@]}" -eq 0 ]; then
                rb_error "SERVICE_CONFIG_TEST が未設定のため A1 は実行できません"
                return 1
            fi
            if ! rb_have_cmd "${SERVICE_CONFIG_TEST[0]}"; then
                rb_error "コマンドが見つかりません: ${SERVICE_CONFIG_TEST[0]}"
                return 1
            fi
            ;;
        A2 | A3)
            if ! systemd_available; then
                rb_error "systemd が利用できない環境のため ${id} は実行できません。"
                rb_error "この環境では、サービスの起動方法に合わせた手順で手動対応してください。"
                return 1
            fi
            if ! rb_run systemctl cat "$WEB_SERVICE" >/dev/null 2>&1; then
                rb_error "サービスユニットが見つかりません: ${WEB_SERVICE}"
                return 1
            fi
            # --- 設定ファイルの構文チェック(失敗したら何もしない) ---
            if [ "${#SERVICE_CONFIG_TEST[@]}" -gt 0 ] && rb_have_cmd "${SERVICE_CONFIG_TEST[0]}"; then
                rb_info "事前チェック: ${SERVICE_CONFIG_TEST[*]} を実行します"
                if ! rb_run_priv "${SERVICE_CONFIG_TEST[@]}"; then
                    rb_error "設定ファイルの構文チェックに失敗しました。${id} は実行しません。"
                    rb_error "壊れた設定のまま反映すると、いま動いているプロセスも起動できなくなります。"
                    return 1
                fi
                rb_info "事前チェック: 構文エラーはありませんでした"
            else
                rb_warn "構文チェックコマンドが使えないため、事前チェックを省略します"
            fi
            ;;
        A4)
            if ! rb_have_cmd logrotate; then
                rb_error "logrotate コマンドが見つかりません"
                return 1
            fi
            if [ ! -r "$LOGROTATE_CONF" ]; then
                rb_error "logrotate 設定ファイルが読めません: ${LOGROTATE_CONF}"
                return 1
            fi
            ;;
        *)
            rb_error "未定義のアクションです: ${id}"
            return 1
            ;;
    esac
    return 0
}

# ---------------------------------------------------------------------
# 短時間に同じ操作を繰り返していないかを監査ログで確認する
#
#   「再起動したのにまた落ちる」を繰り返している場合、
#   原因は別のところにある(設定ミス・リソース枯渇・上流の障害など)。
#   同じ操作を機械的に繰り返すのではなく、
#   人に「立ち止まって考える」きっかけを与えるための仕組み。
# ---------------------------------------------------------------------
recent_same_action_seconds() {
    local id="$1" last_ts="" last_epoch="" now="" diff=0

    [ -r "$AUDIT_LOG" ] || return 1
    last_ts="$(awk -F'\t' -v a="$id" '$5 == "execute" && $6 == a { ts = $1 } END { print ts }' \
        "$AUDIT_LOG" 2>/dev/null)"
    [ -n "$last_ts" ] || return 1

    if ! last_epoch="$(date -d "$last_ts" +%s 2>/dev/null)"; then
        return 1
    fi
    now="$(date +%s)"
    diff=$((now - last_epoch))
    if [ "$diff" -le "${RECENT_ACTION_GUARD_SECONDS:-600}" ]; then
        printf '%s' "$diff"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------
# 復旧できたかどうかの確認(実行後の答え合わせ)
#   戻り値: 0=復旧を確認できた / 1=確認できなかった
# ---------------------------------------------------------------------
verify_recovery() {
    local state="" code="" rc=0 ok=0

    printf '\n--- 実行後の確認 ---\n'

    if systemd_available; then
        state="$(rb_run systemctl is-active "$WEB_SERVICE" 2>/dev/null)"
        printf ' サービス状態 : %s = %s\n' "$WEB_SERVICE" "${state:-取得不可}"
        [ "$state" = "active" ] || ok=1
    else
        printf ' サービス状態 : systemd が無いため確認をスキップしました\n'
    fi

    if rb_have_cmd curl; then
        code="$(rb_run curl -o /dev/null -s -w '%{http_code}' \
            --max-time "$HTTP_TIMEOUT" "$HEALTH_URL" 2>/dev/null)"
        rc=$?
        if [ "$rc" -ne 0 ]; then
            printf ' HTTP応答     : 接続失敗 (curl終了コード=%s)\n' "$rc"
            ok=1
        else
            printf ' HTTP応答     : %s = HTTP %s\n' "$HEALTH_URL" "$code"
            case "$code" in
                2?? | 3??) ;;
                *) ok=1 ;;
            esac
        fi
    else
        printf ' HTTP応答     : curl が無いため確認をスキップしました\n'
    fi

    return "$ok"
}

# ---------------------------------------------------------------------
# Slack通知(任意)
#   復旧操作を実行したことをチームへ共有する。失敗しても本処理は止めない。
# ---------------------------------------------------------------------
notify_slack() {
    local message="$1"
    [ "${ENABLE_SLACK_NOTIFY:-false}" = "true" ] || return 0
    rb_have_cmd curl || return 0
    case "${SLACK_WEBHOOK_URL:-}" in
        http*) ;;
        *)
            rb_warn "SLACK_WEBHOOK_URL が未設定のため通知を送信しません"
            return 0
            ;;
    esac
    rb_run curl -s -X POST -H 'Content-type: application/json' \
        --data "{\"text\": \"${message}\"}" "$SLACK_WEBHOOK_URL" >/dev/null 2>&1 \
        || rb_warn "Slack通知の送信に失敗しました(復旧処理自体は継続します)"
}

# ---------------------------------------------------------------------
# アクションの実行(承認 → 実行 → 記録 → 確認)
# ---------------------------------------------------------------------
run_action() {
    local id="$1"
    local cmd_str="" rc=0 elapsed=0 waited=""

    cmd_str="$(action_command "$id")"

    # --- 1. 許可リストの確認 ---
    if ! is_known_action "$id"; then
        rb_error "未定義のアクションIDです: ${id}(--list で一覧を確認してください)"
        return "$RB_EXIT_ERROR"
    fi
    if ! is_allowed_action "$id"; then
        rb_error "このアクションは設定ファイルで許可されていません: ${id}"
        rb_error "許可されているアクション: ${ALLOWED_ACTIONS}"
        rb_audit "refused" "$id" "$WEB_SERVICE" "REFUSED" "$RB_EXIT_ERROR" \
            "ALLOWED_ACTIONS に含まれていない" || true
        return "$RB_EXIT_ERROR"
    fi

    # --- 2. dry-run: 何をするかだけ表示して終わる ---
    if [ "$DRY_RUN" = "true" ]; then
        printf '\n[DRY-RUN] %s %s [危険度: %s]\n' "$id" "${ACTION_NAME[$id]}" "${ACTION_RISK[$id]}"
        printf '  内容            : %s\n' "${ACTION_DESC[$id]}"
        printf '  実行予定コマンド: %s\n' "$cmd_str"
        case "$id" in
            A2 | A3) printf '  事前チェック    : %s が成功すること\n' "${SERVICE_CONFIG_TEST[*]:-(設定なし)}" ;;
            *) : ;;
        esac
        printf '  → --dry-run のため実行しません\n'
        rb_audit "dry-run" "$id" "$WEB_SERVICE" "DRY_RUN" 0 "$cmd_str" || true
        return "$RB_EXIT_OK"
    fi

    # --- 3. 監査ログに書けることを先に確認する ---
    # 記録が残せないなら実行もしない。「何をしたか分からない変更」を
    # サーバーに加えないための、意図的な制限。
    if ! rb_init_audit_log; then
        rb_error "監査ログを利用できないため、復旧操作は実行しません。"
        rb_error "AUDIT_LOG のパスと権限を確認してください: ${AUDIT_LOG}"
        return "$RB_EXIT_ERROR"
    fi

    # --- 4. 前提チェック ---
    if ! preflight "$id"; then
        rb_audit "refused" "$id" "$WEB_SERVICE" "REFUSED" "$RB_EXIT_ERROR" \
            "前提チェック不成立: ${cmd_str}" || true
        return "$RB_EXIT_ERROR"
    fi

    # --- 5. 直近に同じ操作をしていないか ---
    if waited="$(recent_same_action_seconds "$id")"; then
        rb_warn "${waited}秒前に同じアクション(${id})を実行した記録があります。"
        rb_warn "繰り返しても直らない場合、原因は別にあります。エスカレーションも検討してください。"
    fi

    # --- 6. 人による承認 ---
    if [ "${ACTION_RISK[$id]}" != "low" ]; then
        local prompt=""
        prompt="$(printf '実行しようとしている操作:\n  アクション : %s %s\n  コマンド   : %s\n  影響       : %s\n  対象ホスト : %s' \
            "$id" "${ACTION_NAME[$id]}" "$cmd_str" "${ACTION_DESC[$id]}" "$RB_HOSTNAME")"
        if ! rb_confirm "${ACTION_RISK[$id]}" "$prompt"; then
            printf '\n実行を中止しました。\n'
            rb_audit "execute" "$id" "$WEB_SERVICE" "DECLINED" "$RB_EXIT_DECLINED" \
                "人が承認しなかった、または非対話環境: ${cmd_str}" || true
            return "$RB_EXIT_DECLINED"
        fi
    else
        rb_info "危険度 low(読み取りのみ)のため、確認プロンプトは省略します"
    fi

    # --- 7. 実行 ---
    printf '\n実行: %s\n' "$cmd_str"
    local start_epoch=0
    start_epoch="$(date +%s)"
    action_execute "$id"
    rc=$?
    elapsed=$(( $(date +%s) - start_epoch ))

    if [ "$rc" -eq 0 ]; then
        printf '実行結果: 成功 (%s秒)\n' "$elapsed"
        rb_audit "execute" "$id" "$WEB_SERVICE" "SUCCESS" "$rc" \
            "${cmd_str} (${elapsed}s)" || rb_warn "監査ログの記録に失敗しました"
    else
        if [ "$rc" -eq 124 ]; then
            printf '実行結果: タイムアウト (%s秒で打ち切り)\n' "${CMD_TIMEOUT:-10}"
        else
            printf '実行結果: 失敗 (終了コード=%s)\n' "$rc"
        fi
        rb_audit "execute" "$id" "$WEB_SERVICE" "FAILED" "$rc" \
            "${cmd_str} (${elapsed}s)" || rb_warn "監査ログの記録に失敗しました"
        printf '\n復旧操作が失敗しました。これ以上の自動対応は行いません。\n'
        printf '診断レポートと監査ログを添えてエスカレーションしてください。\n'
        notify_slack ":warning: [${RB_HOSTNAME}] 復旧操作 ${id}(${cmd_str})が失敗しました (実行者: $(rb_actor))"
        return "$RB_EXIT_CRIT"
    fi

    # --- 8. 復旧できたかの確認 ---
    # A1(読み取りのみ)は状態を変えないので確認は不要
    if [ "$id" = "A1" ]; then
        return "$RB_EXIT_OK"
    fi

    if verify_recovery; then
        printf '\n復旧を確認しました。障害対応の記録は %s に残っています。\n' "$AUDIT_LOG"
        rb_audit "verify" "$id" "$WEB_SERVICE" "RECOVERED" 0 "実行後の確認で正常を確認" || true
        notify_slack ":white_check_mark: [${RB_HOSTNAME}] 復旧操作 ${id}(${cmd_str})を実行し、正常を確認しました (実行者: $(rb_actor))"
        return "$RB_EXIT_OK"
    fi

    printf '\nコマンドは成功しましたが、まだ正常に応答していません。\n'
    printf '次の候補を試すか、エスカレーションを検討してください。\n'
    rb_audit "verify" "$id" "$WEB_SERVICE" "NOT_RECOVERED" "$RB_EXIT_CRIT" \
        "実行後の確認で異常が継続" || true
    notify_slack ":warning: [${RB_HOSTNAME}] 復旧操作 ${id} 実行後も異常が継続しています (実行者: $(rb_actor))"
    return "$RB_EXIT_CRIT"
}

# =====================================================================
# メイン処理
# =====================================================================

if [ "$LIST_ONLY" = "true" ]; then
    print_action_list
    exit "$RB_EXIT_OK"
fi

# --- 多重起動の防止 ---
# 2人が同時に再起動を実行すると、片方の操作結果が読めなくなる。
# flock で「同時に1つだけ」を保証する。
LOCK_FILE="${STATE_DIR}/recover.lock"
if mkdir -p "$STATE_DIR" 2>/dev/null && : > "$LOCK_FILE" 2>/dev/null; then
    exec 9>"$LOCK_FILE"
    if rb_have_cmd flock; then
        if ! flock -n 9; then
            rb_die "他の recover.sh が実行中です。完了を待ってから実行してください。"
        fi
    fi
else
    rb_warn "ロックファイルを作成できないため、多重起動チェックを行いません: ${LOCK_FILE}"
fi

rb_info "recover.sh ${SCRIPT_VERSION} を開始します (対象=${WEB_SERVICE}, dry-run=${DRY_RUN})"

# --- アクションが指定されている場合はそれを実行する ---
if [ -n "$OPT_ACTION" ]; then
    run_action "$OPT_ACTION"
    EXIT_CODE=$?
    rb_info "recover.sh を終了します (終了コード=${EXIT_CODE})"
    exit "$EXIT_CODE"
fi

# --- 指定が無い場合は診断結果から候補を提示する ---
if ! build_candidates; then
    exit "$RB_EXIT_OK"
fi

# dry-run のときは、候補すべての実行予定内容を表示して終わる
if [ "$DRY_RUN" = "true" ]; then
    for candidate in "${CANDIDATES[@]}"; do
        run_action "$candidate"
    done
    printf '\n--dry-run のため、実際の操作は何も行っていません。\n'
    exit "$RB_EXIT_OK"
fi

# 端末が無い場合は、候補の提示だけで終了する(勝手に実行しない)
if ! rb_is_interactive; then
    printf '\n端末が無い環境のため、ここで終了します。候補の提示のみ行いました。\n'
    printf '実行する場合は、担当者が端末から recover.sh を実行してください。\n'
    rb_audit "propose" "-" "$WEB_SERVICE" "REFUSED" "$RB_EXIT_DECLINED" \
        "非対話環境のため候補提示のみ" || true
    exit "$RB_EXIT_DECLINED"
fi

printf '\n実行するアクションの番号を入力してください(0 = 何もしない): '
if ! IFS= read -r -t "${CONFIRM_TIMEOUT:-60}" choice; then
    printf '\n入力がタイムアウトしました。何も実行していません。\n'
    exit "$RB_EXIT_DECLINED"
fi

# 入力値の検証(数字以外・範囲外は受け付けない)
case "$choice" in
    "" | 0)
        printf '何も実行していません。\n'
        exit "$RB_EXIT_DECLINED"
        ;;
    *[!0-9]*)
        rb_error "数字を入力してください: ${choice}"
        exit "$RB_EXIT_ERROR"
        ;;
esac

if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#CANDIDATES[@]}" ]; then
    rb_error "1〜${#CANDIDATES[@]} の範囲で入力してください: ${choice}"
    exit "$RB_EXIT_ERROR"
fi

run_action "${CANDIDATES[$((choice - 1))]}"
EXIT_CODE=$?
rb_info "recover.sh を終了します (終了コード=${EXIT_CODE})"
exit "$EXIT_CODE"
