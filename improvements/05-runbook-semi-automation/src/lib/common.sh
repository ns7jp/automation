#!/usr/bin/env bash
# shellcheck disable=SC2034
#   SC2034(未使用の変数)をこのファイル全体で無効化している。
#   ここで定義している定数は「読み込む側のスクリプト」で使うものであり、
#   このファイル単体を静的解析すると未使用に見えてしまうため。
#
# =====================================================================
# lib/common.sh
# 改善案件No.5: 手順書ベースの障害対応の半自動化 - 共通関数ライブラリ
#
# 概要:
#   diagnose.sh(診断)と recover.sh(半自動復旧)の両方から
#   「. lib/common.sh」で読み込んで使う共通関数をまとめたファイル。
#   ログ出力・監査ログ・確認プロンプト・タイムアウト実行など、
#   「2つのスクリプトで同じ書き方をしたい処理」だけを置いている。
#
# 注意:
#   このファイルは単体では実行しない(source されることを前提とした
#   ライブラリ)。先頭のシバン(#!/usr/bin/env bash)は、shellcheck に
#   「これはBashスクリプトである」と伝えるために書いてある。
# =====================================================================

# ---------------------------------------------------------------------
# 終了ステータス(終了コード)の定義
#
# なぜ定数にするのか:
#   終了ステータスは「スクリプトが呼び出し元へ返す唯一の数値」であり、
#   cron・監視ツール・他のスクリプトはこの数値だけを見て次の動作を決める。
#   コードの中に 0 / 1 / 2 という数字を直接書くと意味が読み取れなくなるため、
#   名前を付けて一箇所で管理する。
#
#   0 = 異常なし
#   1 = 警告あり(すぐ落ちる状態ではないが要注意)
#   2 = 異常あり(対応が必要)/ 復旧を試みたが完了しなかった
#   3 = スクリプト自身の実行エラー(設定不備・前提コマンド不足など)
#   4 = 人が実行を承認しなかった / 非対話環境のため実行しなかった
# ---------------------------------------------------------------------
RB_EXIT_OK=0
RB_EXIT_WARN=1
RB_EXIT_CRIT=2
RB_EXIT_ERROR=3
RB_EXIT_DECLINED=4

# ライブラリの版数(監査ログに残して「どの版で実行したか」を追えるようにする)
RB_LIB_VERSION="1.0.0"

# 実行中スクリプト名。呼び出し側で上書きされる想定(未設定なら unknown)。
: "${RB_SCRIPT_NAME:=unknown}"
# 追記先の実行ログ。空文字なら画面のみに出力する。
: "${RB_RUN_LOG:=}"
# true にすると INFO レベルのログを画面に出さない(-q オプション用)。
: "${RB_QUIET:=false}"

RB_HOSTNAME="$(hostname 2>/dev/null || echo unknown-host)"

# ---------------------------------------------------------------------
# 時刻・実行者
# ---------------------------------------------------------------------

# rb_timestamp: 人が読みやすい形式の現在時刻(画面表示用)
rb_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# rb_timestamp_iso: ISO 8601形式の現在時刻(監査ログ用)
#   例: 2026-09-07T03:12:44+0900
#   なぜISO形式か: 文字列として並べ替えるだけで時系列順になり、
#   sort や awk での集計がそのまま使えるため。
rb_timestamp_iso() {
    date '+%Y-%m-%dT%H:%M:%S%z'
}

# rb_actor: 「実際に操作した人」を返す
#   sudo 経由で実行されると id -un は root になってしまい、
#   誰が実行したのか分からなくなる。sudo は元のユーザー名を
#   環境変数 SUDO_USER に入れてくれるので、それを優先して使う。
rb_actor() {
    printf '%s' "${SUDO_USER:-$(id -un)}"
}

# ---------------------------------------------------------------------
# ログ出力
#
# 設計方針:
#   ・ログ(INFO/WARN/ERROR)は「標準エラー出力(stderr)」へ出す
#   ・診断サマリなど「成果物としての出力」は「標準出力(stdout)」へ出す
#   なぜ分けるのか: こうしておくと
#     ./diagnose.sh > summary.txt
#   としたときに、summary.txt にはサマリだけが入り、進捗ログは画面に残る。
# ---------------------------------------------------------------------

rb_log() {
    local level="$1"
    shift
    local line
    line="$(rb_timestamp) [${level}] $*"

    # 実行ログファイルが指定されていれば追記する(書けなくても止めない)
    if [ -n "$RB_RUN_LOG" ]; then
        printf '%s\n' "$line" >> "$RB_RUN_LOG" 2>/dev/null || true
    fi

    # -q(quiet)指定時は INFO を画面に出さない
    if [ "$level" = "INFO" ] && [ "$RB_QUIET" = "true" ]; then
        return 0
    fi
    printf '%s\n' "$line" >&2
}

rb_info()  { rb_log "INFO"  "$@"; }
rb_warn()  { rb_log "WARN"  "$@"; }
rb_error() { rb_log "ERROR" "$@"; }

# rb_die: エラーメッセージを出して「実行エラー」として終了する
rb_die() {
    rb_error "$@"
    exit "$RB_EXIT_ERROR"
}

# ---------------------------------------------------------------------
# コマンドの存在確認とタイムアウト付き実行
# ---------------------------------------------------------------------

# rb_have_cmd: コマンドが使えるかどうかを調べる(あれば0を返す)
rb_have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# rb_run: 外部コマンドを「必ずタイムアウト付き」で実行する
#
# なぜタイムアウトを付けるのか:
#   障害時は、コマンド自体が応答を返さなくなることがよくある
#   (例: NFSが固まっている状態での df、応答しないサービスへの systemctl)。
#   何もしなければスクリプトはそこで永久に止まり、
#   「診断ツールが動かないので障害対応が進まない」という最悪の事態になる。
#   timeout を挟むことで「一定時間で諦めて次へ進む」動きを保証する。
#
#   timeout コマンドは、時間切れで打ち切った場合に終了コード124を返す。
rb_run() {
    local limit="${CMD_TIMEOUT:-10}"
    if rb_have_cmd timeout; then
        timeout "$limit" "$@"
    else
        # timeout が無い環境でも動作は継続する(その旨は呼び出し側で警告済み)
        "$@"
    fi
}

# rb_run_priv: 管理者権限が必要なコマンドを実行する
#
#   ・rootで実行中ならそのまま実行する
#   ・一般ユーザーなら sudo -n(=パスワードを聞かない非対話モード)を付ける
#     sudo -n は許可されていない場合すぐ失敗するので、
#     「パスワード入力待ちでスクリプトが固まる」ことがない(安全側の挙動)。
rb_run_priv() {
    if [ "$(id -u)" -eq 0 ]; then
        rb_run "$@"
        return $?
    fi
    if ! rb_have_cmd sudo; then
        rb_error "管理者権限が必要ですが sudo コマンドがありません: $*"
        return 127
    fi
    rb_run sudo -n "$@"
}

# ---------------------------------------------------------------------
# 設定値のチェック
# ---------------------------------------------------------------------

# rb_require_config: 指定した設定項目が空でないことを確認する
#   ${!name-} は「変数名を格納した変数」から値を取り出す書き方(間接参照)。
rb_require_config() {
    local name
    local missing=0
    for name in "$@"; do
        if [ -z "${!name-}" ]; then
            rb_error "設定ファイルの項目が未設定または空です: ${name}"
            missing=1
        fi
    done
    return "$missing"
}

# ---------------------------------------------------------------------
# 監査ログ
#
# なぜ監査ログが必要か:
#   障害対応の価値は「直したこと」だけでなく「何をしたか説明できること」
#   にもある。誰が・いつ・どのサーバーで・どの操作を・どういう結果で
#   実行したのかが残っていないと、二次障害が起きたときに原因を切り分け
#   られず、再発防止の議論もできない。
#
# フォーマット: タブ区切り(TSV)10列
#   1 実行日時(ISO 8601)
#   2 ホスト名
#   3 実行者(sudo元のユーザー名)
#   4 スクリプト名
#   5 モード(diagnose / dry-run / execute)
#   6 アクションID(診断は "-")
#   7 操作対象(サービス名など)
#   8 結果(SUCCESS / FAILED / DECLINED / REFUSED / DRY_RUN / OK / WARN / CRITICAL)
#   9 終了コード
#  10 補足(自由記述)
#
#   タブ区切りにする理由: awk -F'\t' でそのまま列指定でき、
#   メッセージ中にスペースが含まれていても列がずれないため。
# ---------------------------------------------------------------------

# rb_init_audit_log: 監査ログの置き場所を用意し、書き込めることを確認する
rb_init_audit_log() {
    local log_path="${AUDIT_LOG:-}"
    if [ -z "$log_path" ]; then
        rb_error "AUDIT_LOG が設定されていません"
        return 1
    fi

    local log_dir
    log_dir="$(dirname "$log_path")"
    if [ ! -d "$log_dir" ]; then
        mkdir -p "$log_dir" 2>/dev/null || {
            rb_error "監査ログのディレクトリを作成できません: ${log_dir}"
            return 1
        }
    fi

    # ファイルが無ければヘッダー行付きで作る(後から人が読むときの目印)
    if [ ! -e "$log_path" ]; then
        {
            printf '# runbook-assist audit log (TSV)\n'
            printf '# timestamp\thost\tactor\tscript\tmode\taction\ttarget\tresult\texit_code\tdetail\n'
        } > "$log_path" 2>/dev/null || {
            rb_error "監査ログを作成できません: ${log_path}"
            return 1
        }
        chmod 640 "$log_path" 2>/dev/null || true
    fi

    if [ ! -w "$log_path" ]; then
        rb_error "監査ログに書き込み権限がありません: ${log_path}"
        return 1
    fi
    return 0
}

# rb_audit: 監査ログを1行追記する
#   引数: モード アクションID 対象 結果 終了コード [補足...]
#   戻り値: 0=記録できた / 1=記録できなかった
#
#   補足に含まれるタブ・改行はスペースへ置換する(列ずれ防止)。
rb_audit() {
    local mode="$1" action="$2" target="$3" result="$4" code="$5"
    shift 5
    local detail="$*"
    detail="$(printf '%s' "$detail" | tr '\t\n' '  ')"

    local log_path="${AUDIT_LOG:-}"
    if [ -z "$log_path" ]; then
        rb_error "AUDIT_LOG が設定されていないため監査ログを記録できません"
        return 1
    fi

    if ! printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(rb_timestamp_iso)" \
        "$RB_HOSTNAME" \
        "$(rb_actor)" \
        "$RB_SCRIPT_NAME" \
        "$mode" \
        "$action" \
        "$target" \
        "$result" \
        "$code" \
        "$detail" >> "$log_path" 2>/dev/null; then
        rb_error "監査ログへの書き込みに失敗しました: ${log_path}"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------
# 確認プロンプト
# ---------------------------------------------------------------------

# rb_is_interactive: 標準入力・標準出力の両方が端末(キーボードと画面)か
#   [ -t 0 ] は「標準入力が端末につながっているか」を判定する書き方。
#   cron や CI から実行された場合は端末が無いので false になる。
rb_is_interactive() {
    [ -t 0 ] && [ -t 1 ]
}

# rb_confirm: 実行前に人の承認を取る
#   引数1: リスク区分(low / medium / high)
#   引数2以降: 表示するメッセージ
#   戻り値: 0=承認された / 1=承認されなかった(非対話・タイムアウト含む)
#
# 設計上のポイント:
#   1. 非対話環境では「承認できない」ではなく「実行しない」を選ぶ。
#      勝手に実行するより、何もしない方が安全だという判断(安全側に倒す)。
#   2. read には -t でタイムアウトを設ける。担当者が席を離れたまま
#      プロンプトが残り続けて、後から誰かが誤って Enter を押す事故を防ぐ。
#      時間切れは「no」と同じ扱いにする。
#   3. リスクが high の操作は y ではなく yes と全文字入力させる。
#      キー1つの反射的な承認を物理的に難しくするための仕掛け。
rb_confirm() {
    local risk="$1"
    shift
    local message="$*"
    local timeout_sec="${CONFIRM_TIMEOUT:-60}"
    local answer=""

    if ! rb_is_interactive; then
        rb_error "非対話環境(端末なし)のため承認を取得できません。実行を中止します。"
        rb_error "内容だけ確認したい場合は --dry-run を付けて実行してください。"
        return 1
    fi

    printf '\n%s\n' "$message" >&2

    if [ "$risk" = "high" ]; then
        printf '  この操作はサービスに影響します。実行するなら yes と入力 [yes/no] (%s秒で中止): ' \
            "$timeout_sec" >&2
        if ! IFS= read -r -t "$timeout_sec" answer; then
            printf '\n' >&2
            rb_warn "入力がタイムアウトしました。実行しません。"
            return 1
        fi
        if [ "$answer" = "yes" ]; then
            return 0
        fi
        return 1
    fi

    printf '  実行しますか? [y/N] (%s秒で中止): ' "$timeout_sec" >&2
    if ! IFS= read -r -t "$timeout_sec" answer; then
        printf '\n' >&2
        rb_warn "入力がタイムアウトしました。実行しません。"
        return 1
    fi
    case "$answer" in
        y | Y | yes | YES | Yes) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------
# 診断結果ファイル(KEY=VALUE形式)の読み取り
#
#   diagnose.sh が書き出した結果を recover.sh が読むために使う。
#
#   なぜ source(読み込んで実行)しないのか:
#     source はファイルの中身をそのままBashのコードとして実行するため、
#     万一ファイルが書き換えられていると任意のコマンドが動いてしまう。
#     ここでは「値を取り出すだけ」なので、grep で該当行を取り出して
#     "=" の右側を切り出す方法にしている(実行はしない)。
# ---------------------------------------------------------------------
rb_read_finding() {
    local key="$1"
    local file="$2"
    local line=""

    [ -r "$file" ] || return 1
    # キー名は英大文字・数字・アンダースコアのみ許可(想定外の入力を弾く)
    case "$key" in
        *[!A-Z0-9_]*) return 1 ;;
    esac

    line="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n 1)"
    [ -n "$line" ] || return 1
    printf '%s' "${line#*=}"
}
