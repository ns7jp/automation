#!/usr/bin/env bash
#
# =====================================================================
# opslib.sh — 運用スクリプト共通ライブラリ
# 改善案件No.2: コピペで増えた運用スクリプトの共通処理を1ファイルに集約する
#
# このファイルは「実行する」ものではなく「読み込む(source する)」もの。
# 各運用スクリプトの冒頭で source して、以下の共通関数を使う。
#
#   source "$(dirname "${BASH_SOURCE[0]}")/opslib.sh"
#
# --- 提供する関数 ---------------------------------------------------
#   ops_log_init <ログファイルパス>   ログ出力先を設定する
#   ops_log <レベル> <メッセージ...>  統一書式でログを出力する
#   ops_log_debug / ops_log_info / ops_log_warn / ops_log_error
#                                     よく使うレベルの短縮版
#   ops_load_config <設定ファイル>    設定ファイルを検証して読み込む
#   ops_require_commands <コマンド...> 必要なコマンドの存在をまとめて確認
#   ops_slack_payload <本文>          Slack用のJSONを安全に組み立てる
#   ops_notify_slack <本文>           Slackへ通知を送る
#   ops_lib_version                   ライブラリのバージョンを表示する
#
# --- 設計上の約束(ライブラリ設計の原則) ---------------------------
#   1. 呼び出し側の変数に暗黙に依存しない。
#      必要な値は必ず引数か OPS_ で始まる専用変数から受け取る。
#      (例: 旧 log() は呼び出し側の $LOG_FILE に暗黙依存していた)
#   2. 副作用を減らす。ライブラリは set -e / set -u などのシェル
#      オプションを勝手に変更しない。呼び出し側の方針を尊重するため。
#   3. ライブラリの中で exit しない。異常は戻り値(return)で伝える。
#      ライブラリが勝手に exit すると、呼び出し側が「後片付け処理」を
#      実行できないまま強制終了させられてしまうため。
#   4. 名前は必ず ops_ (公開) / _ops_ (内部用) で始める。
#      呼び出し側の関数名・変数名と衝突しないようにするため。
#
# --- 依存コマンド ---------------------------------------------------
#   date, printf, mkdir  … 標準で入っている
#   curl, jq             … Slack通知を使う場合のみ必要
#
# ライセンス/前提: Bash 4.0以上、Ubuntu Server 22.04 LTS で動作確認
# =====================================================================

# ---------------------------------------------------------------------
# 直接実行された場合の警告(この判定を先に行う)
#
#   なぜ: このファイルは source されて初めて意味がある。
#   うっかり ./opslib.sh と実行しても何も起きず「動かない」と
#   悩んでしまうため、使い方を表示して終了する。
#
#   ${BASH_SOURCE[0]} は「今読み込まれているファイル自身のパス」、
#   $0 は「最初に起動されたスクリプトのパス」。
#   source された場合は両者が異なり、直接実行された場合は一致する。
#
#   この判定を二重読み込み防止より先に置いているのは、直接実行時に
#   関数の外で return を実行してしまうエラーを避けるため
#   (return はシェル関数の中か、source されたファイルの中でしか使えない)。
# ---------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "opslib.sh は共通ライブラリです。直接実行せず、スクリプトから source して使ってください。" >&2
    echo "  例: source \"\$(dirname \"\${BASH_SOURCE[0]}\")/opslib.sh\"" >&2
    exit 1
fi

# ---------------------------------------------------------------------
# 二重読み込み(多重 source)の防止
#
#   なぜ: A.sh が opslib.sh を source し、さらに B.sh も source する、
#   といった構成になると同じファイルが2回読み込まれる。関数の再定義自体は
#   無害だが、無駄な処理が増えるうえ「読み込み済みかどうか」を判定できると
#   デバッグが楽になる。既に読み込み済みなら何もせずに戻る。
#
#   ${OPS_LIB_VERSION:-} と書いているのは、呼び出し側が set -u
#   (未定義変数の参照をエラーにする)を有効にしていても安全に判定するため。
#   ":-" は「未定義なら空文字として扱う」というパラメータ展開。
# ---------------------------------------------------------------------
if [ -n "${OPS_LIB_VERSION:-}" ]; then
    return 0
fi

# ライブラリのバージョン。二重読み込み防止の目印も兼ねる。
OPS_LIB_VERSION="1.0.0"

# ---------------------------------------------------------------------
# 設定変数の既定値
#
#   ":=" は「未定義または空なら、この値を代入する」パラメータ展開。
#   呼び出し側が source の前に値を設定していれば、そちらが優先される。
#   すべて OPS_ で始めているのは、呼び出し側の変数と名前が衝突しないようにするため。
# ---------------------------------------------------------------------

# OPS_LOG_FILE: ログの追記先ファイル。空ならファイル出力せず画面のみ。
: "${OPS_LOG_FILE:=}"

# OPS_LOG_TAG: ログ行に入れる出力元の識別子。
#   複数スクリプトのログを1か所に集めたときに「どのスクリプトの行か」を
#   区別できるようにするためのもの。既定は実行中スクリプトのファイル名から
#   拡張子を除いたもの(例: backup.sh -> backup)。
: "${OPS_LOG_TAG:=$(basename "${0%.sh}")}"

# OPS_LOG_LEVEL: この重要度未満のログは出力しない。DEBUG/INFO/WARN/ERROR。
: "${OPS_LOG_LEVEL:=INFO}"

# OPS_SLACK_ENABLED: "true" 以外なら Slack 通知を行わない。
: "${OPS_SLACK_ENABLED:=true}"

# OPS_SLACK_WEBHOOK_URL: Slack Incoming Webhook の URL。
: "${OPS_SLACK_WEBHOOK_URL:=}"

# OPS_SLACK_TIMEOUT: Slack への送信を諦めるまでの秒数。
#   通知が返ってこないせいで運用スクリプト全体が止まるのを防ぐため。
: "${OPS_SLACK_TIMEOUT:=10}"

# OPS_SLACK_DRY_RUN: "true" なら実際には送信せず、送る予定のJSONを標準出力に出す。
#   テストや動作確認でSlackを汚さずに検証するために用意している。
: "${OPS_SLACK_DRY_RUN:=false}"

# 内部用フラグ: ログファイルへの書き込み失敗を1度だけ警告するために使う。
_OPS_LOG_FILE_WARNED="false"

#======================================================================
# 内部関数(_ops_ で始まる。呼び出し側から直接使うことは想定しない)
#======================================================================

# _ops_timestamp: 統一書式の日時文字列を返す
#   出力: "2026-09-07 04:30:00"
_ops_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# _ops_level_priority: ログレベル名を数値の優先度に変換する
#   引数1: レベル名(DEBUG/INFO/WARN/ERROR、それ以外も可)
#   出力  : 優先度の数値。大きいほど重要。
#
#   なぜ数値にするか: 文字列のままでは「WARN は INFO より重要か」を
#   比較できないため。数値に直すことで単純な大小比較で判定できる。
#   未知のレベル(例: 案件No.1で使っていた "SKIP")は INFO と同じ扱いにして、
#   既存スクリプトの独自レベルが消えてしまわないようにしている。
_ops_level_priority() {
    case "$1" in
        DEBUG) echo 10 ;;
        INFO)  echo 20 ;;
        WARN)  echo 30 ;;
        ERROR) echo 40 ;;
        *)     echo 20 ;;
    esac
}

#======================================================================
# 公開関数
#======================================================================

# ---------------------------------------------------------------------
# ops_lib_version: ライブラリのバージョンを標準出力に表示する
#   使い方: ops_lib_version   ->  1.0.0
# ---------------------------------------------------------------------
ops_lib_version() {
    printf '%s\n' "$OPS_LIB_VERSION"
}

# ---------------------------------------------------------------------
# ops_log_init: ログの出力先ファイルを設定し、書き込める状態にする
#   引数1: ログファイルのパス
#   戻り値: 0=成功 / 1=ディレクトリ作成またはファイル作成に失敗
#
#   なぜ専用の初期化関数を用意するか:
#   ログ出力のたびにディレクトリの存在確認をすると無駄が多い。
#   また「ログが書けない」ことは起動時に気づきたい問題なので、
#   処理を始める前にまとめて確認しておく。
# ---------------------------------------------------------------------
ops_log_init() {
    local _ops_path="$1"
    local _ops_dir

    _ops_dir="$(dirname "$_ops_path")"

    # -p : 親ディレクトリごと作成し、既に存在してもエラーにしない
    if ! mkdir -p "$_ops_dir" 2> /dev/null; then
        echo "$(_ops_timestamp) [ERROR] [${OPS_LOG_TAG}] ログディレクトリを作成できません: ${_ops_dir}" >&2
        return 1
    fi

    # touch でファイルを作成(既にあれば更新日時だけ変わる)。
    # ここで失敗するなら権限不足であり、あとからログが書けないと分かるより
    # 起動直後に分かったほうが調査が早い。
    if ! touch "$_ops_path" 2> /dev/null; then
        echo "$(_ops_timestamp) [ERROR] [${OPS_LOG_TAG}] ログファイルに書き込めません: ${_ops_path}" >&2
        return 1
    fi

    OPS_LOG_FILE="$_ops_path"
    _OPS_LOG_FILE_WARNED="false"
    return 0
}

# ---------------------------------------------------------------------
# ops_log: 統一書式でログを出力する
#   引数1   : ログレベル(INFO / WARN / ERROR / DEBUG など)
#   引数2以降: メッセージ本文
#   戻り値  : 常に 0(ログ出力の失敗で処理を止めないため)
#
#   出力書式(このライブラリで統一した唯一の書式):
#     YYYY-MM-DD HH:MM:SS [レベル] [タグ] メッセージ
#     例) 2026-09-07 04:30:00 [INFO] [backup] バックアップを開始します
#
#   この書式にした理由:
#     ・日時が行頭にあるので、複数ログを cat して sort するだけで
#       時系列順に並べられる(先頭に "[" が付いていると並べ替えの邪魔になる)
#     ・区切りが半角スペースなので awk '{print $3}' でレベルだけ、
#       awk '{print $4}' でタグだけを簡単に取り出せる
#     ・タグ列があるので、複数スクリプトのログを1つにまとめても
#       どのスクリプトの行かを判別できる
#
#   出力先:
#     ・ERROR は標準エラー出力、それ以外は標準出力へ。
#       cron は標準エラー出力に出た内容を管理者へメール通知する仕組みが
#       あるため、異常だけを分けておくと気づきやすい。
#     ・OPS_LOG_FILE が設定されていれば、同じ1行をファイルにも追記する。
# ---------------------------------------------------------------------
ops_log() {
    local _ops_level="$1"
    shift
    local _ops_message="$*"

    # --- レベルによる出力抑制の判定 ---
    local _ops_this_priority _ops_min_priority
    _ops_this_priority="$(_ops_level_priority "$_ops_level")"
    _ops_min_priority="$(_ops_level_priority "$OPS_LOG_LEVEL")"
    if [ "$_ops_this_priority" -lt "$_ops_min_priority" ]; then
        return 0
    fi

    local _ops_line
    _ops_line="$(_ops_timestamp) [${_ops_level}] [${OPS_LOG_TAG}] ${_ops_message}"

    # --- 画面への出力 ---
    if [ "$_ops_level" = "ERROR" ]; then
        printf '%s\n' "$_ops_line" >&2
    else
        printf '%s\n' "$_ops_line"
    fi

    # --- ファイルへの追記 ---
    # 旧実装は `| tee -a "$LOG_FILE"` を使っていたが、ログ1行ごとに
    # tee プロセスを起動するため無駄がある。ここでは追記リダイレクト
    # (>>)だけで済ませている。
    if [ -n "$OPS_LOG_FILE" ]; then
        if ! printf '%s\n' "$_ops_line" >> "$OPS_LOG_FILE" 2> /dev/null; then
            # 書き込めなくても処理は止めない。ただし毎行警告すると
            # 画面が警告で埋まってしまうため、最初の1回だけ知らせる。
            if [ "$_OPS_LOG_FILE_WARNED" != "true" ]; then
                printf '%s\n' "$(_ops_timestamp) [WARN] [${OPS_LOG_TAG}] ログファイルに書き込めません(以後この警告は表示しません): ${OPS_LOG_FILE}" >&2
                _OPS_LOG_FILE_WARNED="true"
            fi
        fi
    fi

    return 0
}

# --- よく使うレベルの短縮版 ---
# 毎回 ops_log "INFO" と書くより読みやすく、レベル名の打ち間違いも防げる。
ops_log_debug() { ops_log "DEBUG" "$@"; }
ops_log_info()  { ops_log "INFO"  "$@"; }
ops_log_warn()  { ops_log "WARN"  "$@"; }
ops_log_error() { ops_log "ERROR" "$@"; }

# ---------------------------------------------------------------------
# ops_require_commands: 必要な外部コマンドが揃っているかまとめて確認する
#   引数: 確認したいコマンド名を必要なだけ並べる
#   戻り値: 0=すべて存在する / 1=1つ以上見つからない
#
#   旧実装(案件No.3の require_command)との違い:
#     旧実装は1つ見つからない時点で exit していた。そのため
#     「jq も curl も入っていない」場合、jq を入れて再実行して初めて
#     curl も無いと分かる、という二度手間が起きる。
#     この関数は最後まで確認し、足りないものをすべて列挙してから返す。
#     また exit せず戻り値で返すので、呼び出し側が終了方法を決められる。
# ---------------------------------------------------------------------
ops_require_commands() {
    local _ops_missing=""
    local _ops_cmd

    for _ops_cmd in "$@"; do
        # command -v <名前> : そのコマンドが実行可能かを調べる標準的な方法。
        # which と違い、シェルの組み込みコマンドや別名も正しく判定できる。
        if ! command -v "$_ops_cmd" > /dev/null 2>&1; then
            _ops_missing="${_ops_missing} ${_ops_cmd}"
        fi
    done

    if [ -n "$_ops_missing" ]; then
        # ${変数# パターン} は先頭の余分な半角スペース1つを取り除く記法
        ops_log_error "必要なコマンドが見つかりません:${_ops_missing} (例: sudo apt-get install -y${_ops_missing})"
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------
# ops_load_config: 設定ファイルを検証してから読み込む(source する)
#   引数1: 設定ファイルのパス
#   戻り値: 0=読み込み成功 / 1=ファイルが無い・読めない
#
#   検証してから読み込む理由:
#     source は「そのファイルの中身をシェルのコマンドとして実行する」命令。
#     ファイルが無いまま source すると分かりにくいエラーになるため、
#     先に存在と読み取り権限を確認し、日本語の明快なメッセージを出す。
#
#   権限チェックについて:
#     設定ファイルにはWebhook URLなどの秘匿情報が入る想定のため、
#     他人から読める権限になっていたら警告する(処理は止めない)。
#     止めないのは、権限が緩いだけで運用が停止すると困る場面があるため。
# ---------------------------------------------------------------------
ops_load_config() {
    local _ops_cfg="$1"

    if [ ! -f "$_ops_cfg" ]; then
        ops_log_error "設定ファイルが見つかりません: ${_ops_cfg}"
        return 1
    fi

    if [ ! -r "$_ops_cfg" ]; then
        ops_log_error "設定ファイルの読み取り権限がありません: ${_ops_cfg}"
        return 1
    fi

    # stat -c '%a' : ファイルの権限を 8進数3桁(例: 600)で表示する
    local _ops_perm
    _ops_perm="$(stat -c '%a' "$_ops_cfg" 2> /dev/null || echo "")"
    case "$_ops_perm" in
        600 | 400 | "") : ;;  # 適切、または権限を取得できなかった場合は何もしない
        *)
            ops_log_warn "設定ファイルの権限が緩いです(現在: ${_ops_perm})。秘匿情報を含む場合は chmod 600 ${_ops_cfg} を推奨します"
            ;;
    esac

    # shellcheck source=/dev/null
    # ↑ 読み込むファイルのパスが実行時に決まるため、shellcheck は中身を
    #   解析できない。それを承知の上であることを明示する指示コメント。
    #   これが無いと SC1090 の警告が出る。
    if ! source "$_ops_cfg"; then
        ops_log_error "設定ファイルの読み込み中にエラーが発生しました: ${_ops_cfg}"
        return 1
    fi

    ops_log_debug "設定ファイルを読み込みました: ${_ops_cfg}"
    return 0
}

# ---------------------------------------------------------------------
# ops_slack_payload: Slackへ送るJSONを安全に組み立てて標準出力へ出す
#   引数1: メッセージ本文
#   戻り値: 0=成功 / 2=jq が無い
#
#   ここがこの改善案件の核心。
#   旧実装(案件No.2 / No.4)は次のように文字列連結で作っていた。
#
#       --data "{\"text\": \"${message}\"}"
#
#   この書き方では、message に " や \ や改行が含まれた瞬間に
#   JSONの構造が壊れ、Slackから HTTP 400 が返って通知が届かなくなる。
#   jq -n --arg に渡せば、jq がJSONの規則どおりにエスケープしてくれる。
#
#   jq に依存させた理由:
#     エスケープ処理を自前のBashで書くこともできるが、制御文字や
#     Unicodeの扱いまで正しく実装するのは難しく、バグの温床になる。
#     「難しい処理は実績のある道具に任せる」という判断をしている。
#     (この案件自体が「自作の手組みJSONで事故った」実例である)
# ---------------------------------------------------------------------
ops_slack_payload() {
    local _ops_text="$1"

    if ! command -v jq > /dev/null 2>&1; then
        ops_log_error "jq が見つかりません。Slack通知には jq が必要です(sudo apt-get install -y jq)"
        return 2
    fi

    # jq -n : 入力を読まずにJSONを新規生成する
    # --arg text "$_ops_text" : シェルの文字列をJSON文字列として安全に渡す
    # -c    : 1行(compact)で出力する
    jq -nc --arg text "$_ops_text" '{text: $text}'
}

# ---------------------------------------------------------------------
# ops_notify_slack: Slack Incoming Webhook へ通知を送る
#   引数1: メッセージ本文
#   戻り値: 0=送信成功(または通知が無効で送る必要がない)
#           1=送信したが失敗した(HTTP 200以外・接続エラー)
#           2=設定不足や前提コマンド不足で送信できなかった
#
#   戻り値を3種類に分けている理由:
#     「そもそも送る設定になっていない(正常)」と「送ろうとしたが失敗した
#     (異常)」を呼び出し側が区別できるようにするため。旧実装は戻り値を
#     一切返しておらず、通知が失敗しても誰も気づけなかった。
#
#   このライブラリは通知失敗を「ログに残すが exit はしない」方針にしている。
#   通知はあくまで補助機能であり、通知の失敗で本来の運用処理(バックアップ等)
#   まで止めてしまうのは本末転倒だからである。
# ---------------------------------------------------------------------
ops_notify_slack() {
    local _ops_message="$1"

    # --- 通知が無効化されている場合は何もせず正常終了 ---
    if [ "$OPS_SLACK_ENABLED" != "true" ]; then
        ops_log_debug "Slack通知は無効(OPS_SLACK_ENABLED=${OPS_SLACK_ENABLED})のため送信しません"
        return 0
    fi

    # --- ペイロードの組み立て(ここでエスケープが保証される) ---
    local _ops_payload
    if ! _ops_payload="$(ops_slack_payload "$_ops_message")"; then
        return 2
    fi

    # --- ドライラン: 送信せず、送る予定のJSONを表示するだけ ---
    if [ "$OPS_SLACK_DRY_RUN" = "true" ]; then
        ops_log_info "Slack通知(ドライラン。実際には送信しません): ${_ops_payload}"
        return 0
    fi

    if [ -z "$OPS_SLACK_WEBHOOK_URL" ]; then
        ops_log_error "OPS_SLACK_WEBHOOK_URL が設定されていないため、Slack通知を送信できません"
        return 2
    fi

    if ! ops_require_commands curl; then
        return 2
    fi

    # -s  : 進捗表示を出さない / -S : エラーだけは表示する
    # -o /dev/null : 応答本文は使わないので捨てる
    # -w '%{http_code}' : HTTPステータスコードだけを標準出力に出す
    # --max-time : 応答が無い場合に無限待ちしないための上限秒数
    local _ops_status
    _ops_status="$(curl -sS -o /dev/null -w '%{http_code}' \
        --max-time "$OPS_SLACK_TIMEOUT" \
        -X POST \
        -H 'Content-type: application/json' \
        --data "$_ops_payload" \
        "$OPS_SLACK_WEBHOOK_URL" 2> /dev/null)"

    if [ "$_ops_status" = "200" ]; then
        ops_log_info "Slack通知を送信しました(HTTP ${_ops_status})"
        return 0
    fi

    ops_log_error "Slack通知の送信に失敗しました(HTTP ${_ops_status:-応答なし})"
    return 1
}
