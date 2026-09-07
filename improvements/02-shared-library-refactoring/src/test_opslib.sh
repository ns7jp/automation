#!/usr/bin/env bash
#
# =====================================================================
# test_opslib.sh — opslib.sh の簡易テスト
# 改善案件No.2: 共通ライブラリが期待どおり動くことを機械的に確認する
#
# なぜテストを書くのか(リファクタリングとテストの関係):
#   リファクタリング(=外から見た動きを変えずに、内部の作りを整理すること)
#   で最も怖いのは「整理したつもりが、こっそり動きを変えてしまう」こと。
#   4本のスクリプトが同じライブラリを使う構成では、ライブラリの1行の
#   ミスが4本すべてに一度に波及する。集約はメリットだけでなく
#   「壊れたときの影響範囲も広がる」という側面があるため、
#   ライブラリ側にテストを用意して安全網を張っておく。
#
# 特別なテストフレームワークは使わず、Bashの機能だけで書いている。
#   ・追加インストール不要ですぐ動かせる
#   ・中身が読めば分かるので、学習用途に向いている
#
# 使い方:
#   ./test_opslib.sh
#
# 終了ステータス:
#   0 : 全テスト成功
#   1 : 1件以上失敗
#
# 依存コマンド: jq(Slackペイロードのテストで使用)
# =====================================================================

# -u : 未定義変数の参照をエラーにする。
#      ライブラリが set -u 環境でも安全に動くことを、このテスト自体が確認している。
# -o pipefail : パイプの途中の失敗を見逃さない。
# ※ -e は付けない。失敗するはずのケース(戻り値1や2が返るケース)を
#    意図的に呼び出すため、失敗した時点で止められると困る。
# ファイル全体に対する shellcheck への指示。
#   OPS_LOG_TAG / OPS_LOG_FILE / OPS_SLACK_ENABLED などの設定変数は、
#   代入したあと opslib.sh の中の関数から参照される。しかし shellcheck は
#   既定では source 先のファイルを解析しないため、「代入したが使っていない
#   変数(SC2034)」だと誤判定してしまう。
#   `shellcheck -x test_opslib.sh` と -x(source先も解析する)を付ければ
#   正しく判定されるが、-x なしで実行されても警告が出ないよう明示的に抑止する。
#   ※ この指示行は「ファイル内の最初のコマンドより前」に置く必要がある。
#     途中に書くと、直後の1コマンドにしか効かない。
# shellcheck disable=SC2034

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- テスト対象のライブラリを読み込む ---
# shellcheck source=./opslib.sh
source "${SCRIPT_DIR}/opslib.sh"

# --- 一時作業ディレクトリ ---
# mktemp -d : 他のプロセスと衝突しない一時ディレクトリを安全に作る。
# trap で終了時に必ず削除し、テストのゴミを残さないようにする。
TEST_TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TEST_TMP_DIR}"' EXIT

# --- テスト結果のカウンタ ---
TEST_PASS=0
TEST_FAIL=0

#======================================================================
# アサーション(=「こうなっているはず」を確認する)ヘルパー
#======================================================================

# assert_equals: 期待値と実際の値が完全一致するか確認する
#   引数1: テスト名 / 引数2: 期待値 / 引数3: 実際の値
assert_equals() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  [PASS] ${name}"
        TEST_PASS=$((TEST_PASS + 1))
    else
        echo "  [FAIL] ${name}"
        echo "         期待値: >${expected}<"
        echo "         実際値: >${actual}<"
        TEST_FAIL=$((TEST_FAIL + 1))
    fi
}

# assert_contains: 実際の値に、期待する部分文字列が含まれるか確認する
#   引数1: テスト名 / 引数2: 含まれるべき文字列 / 引数3: 実際の値
assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    # == の右辺を "*文字列*" と書くとワイルドカード一致になる([[ ]] 内のみ)
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  [PASS] ${name}"
        TEST_PASS=$((TEST_PASS + 1))
    else
        echo "  [FAIL] ${name}"
        echo "         含まれるべき文字列: >${needle}<"
        echo "         実際値            : >${haystack}<"
        TEST_FAIL=$((TEST_FAIL + 1))
    fi
}

# assert_status: 実行した関数の戻り値(終了ステータス)が期待どおりか確認する
#   引数1: テスト名 / 引数2: 期待する戻り値 / 引数3以降: 実行するコマンド
assert_status() {
    local name="$1" expected="$2"
    shift 2

    # 出力は結果の判定に使わないので捨てる。ここで見たいのは戻り値だけ。
    "$@" > /dev/null 2>&1
    local actual=$?

    if [ "$expected" -eq "$actual" ]; then
        echo "  [PASS] ${name}"
        TEST_PASS=$((TEST_PASS + 1))
    else
        echo "  [FAIL] ${name}(期待する戻り値: ${expected} / 実際: ${actual})"
        TEST_FAIL=$((TEST_FAIL + 1))
    fi
}

echo "==================================================================="
echo " opslib.sh 簡易テスト (バージョン: $(ops_lib_version))"
echo "==================================================================="

#======================================================================
echo ""
echo "[1] ログ出力 ops_log"
#======================================================================

# --- 1-1 統一書式で出力されること ---
# OPS_LOG_TAG を固定してから実行し、出力を丸ごと文字列として受け取る。
OPS_LOG_TAG="testtag"
OPS_LOG_FILE=""
OPS_LOG_LEVEL="INFO"

log_line="$(ops_log "INFO" "テストメッセージ")"

# 日時部分は実行するたびに変わるため、日時を除いた後半部分だけを比較する。
# cut -d' ' -f3- : 半角スペース区切りで3番目以降を取り出す(=日付と時刻を捨てる)
log_body="$(printf '%s' "$log_line" | cut -d' ' -f3-)"
assert_equals "統一書式 '[レベル] [タグ] 本文' で出力される" \
    "[INFO] [testtag] テストメッセージ" "$log_body"

# --- 1-2 日時が 'YYYY-MM-DD HH:MM:SS ' 形式で先頭に付くこと ---
# =~ は正規表現マッチ。^ は行頭、[0-9]{4} は数字4桁を意味する。
if [[ "$log_line" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\  ]]; then
    echo "  [PASS] 行頭が 'YYYY-MM-DD HH:MM:SS ' 形式である"
    TEST_PASS=$((TEST_PASS + 1))
else
    echo "  [FAIL] 行頭が 'YYYY-MM-DD HH:MM:SS ' 形式である(実際: ${log_line})"
    TEST_FAIL=$((TEST_FAIL + 1))
fi

# --- 1-3 ERROR は標準エラー出力に出ること ---
# 1>/dev/null で標準出力だけを捨て、2>&1 で標準エラー出力を受け取る。
err_only="$(ops_log "ERROR" "異常メッセージ" 2>&1 1> /dev/null)"
assert_contains "ERRORレベルは標準エラー出力に出る" "[ERROR] [testtag] 異常メッセージ" "$err_only"

# --- 1-4 INFO は標準エラー出力には出ないこと ---
info_on_stderr="$(ops_log "INFO" "通常メッセージ" 2>&1 1> /dev/null)"
assert_equals "INFOレベルは標準エラー出力には出ない" "" "$info_on_stderr"

#======================================================================
echo ""
echo "[2] ログファイル出力 ops_log_init"
#======================================================================

# --- 2-1 存在しない階層でも作成されること ---
log_path="${TEST_TMP_DIR}/logs/deep/test.log"
assert_status "ops_log_init は親ディレクトリごと作成して成功する" 0 ops_log_init "$log_path"

# --- 2-2 画面とファイルの両方に同じ行が出ること ---
ops_log "INFO" "ファイルにも書かれるはず" > /dev/null
file_body="$(tail -n 1 "$log_path" | cut -d' ' -f3-)"
assert_equals "ログファイルに同じ内容が追記される" \
    "[INFO] [testtag] ファイルにも書かれるはず" "$file_body"

# --- 2-3 追記であって上書きではないこと ---
# 世代をまたいで記録を残すには追記でなければならない。
ops_log "INFO" "2行目" > /dev/null
line_count="$(wc -l < "$log_path")"
assert_equals "ログは上書きではなく追記される" "2" "$line_count"

# --- 2-4 書き込めない場所を指定したら戻り値1(exitしない) ---
assert_status "書き込めないパスでは戻り値1を返す(exitしない)" 1 \
    ops_log_init "/proc/definitely-not-writable/test.log"

# 後続のテストに影響しないよう、ログのファイル出力を止める
OPS_LOG_FILE=""

#======================================================================
echo ""
echo "[3] ログレベルによる抑制"
#======================================================================

OPS_LOG_LEVEL="WARN"
debug_out="$(ops_log_debug "これは出ないはず")"
info_out="$(ops_log_info "これも出ないはず")"
warn_out="$(ops_log_warn "これは出るはず")"

assert_equals "OPS_LOG_LEVEL=WARN のとき DEBUG は出力されない" "" "$debug_out"
assert_equals "OPS_LOG_LEVEL=WARN のとき INFO は出力されない" "" "$info_out"
assert_contains "OPS_LOG_LEVEL=WARN のとき WARN は出力される" "これは出るはず" "$warn_out"

# --- 未知のレベル名(案件No.1が使っていた SKIP)が消えないこと ---
OPS_LOG_LEVEL="INFO"
skip_out="$(ops_log "SKIP" "既存ユーザーのためスキップ")"
assert_contains "未知のレベル(SKIP)もINFO相当として出力される" \
    "[SKIP] [testtag] 既存ユーザーのためスキップ" "$skip_out"

#======================================================================
echo ""
echo "[4] Slackペイロードの組み立て ops_slack_payload(この案件の核心)"
#======================================================================

# check_json_roundtrip: 生成したJSONが妥当で、かつ元の文字列に戻せることを確認する
#   引数1: テスト名 / 引数2: 元のメッセージ本文
#
#   「妥当なJSONである」だけでは不十分で、「中身が元通りに取り出せる」ことまで
#   確認して初めてエスケープが正しいと言える。
check_json_roundtrip() {
    local name="$1" original="$2"
    local payload restored

    payload="$(ops_slack_payload "$original")"

    # jq empty : JSONとして読めるかどうかだけを確認する
    if ! printf '%s' "$payload" | jq empty > /dev/null 2>&1; then
        echo "  [FAIL] ${name}: 生成されたJSONが壊れている(${payload})"
        TEST_FAIL=$((TEST_FAIL + 1))
        return
    fi

    # jq -r '.text' : text フィールドの中身を、そのままの文字列として取り出す
    restored="$(printf '%s' "$payload" | jq -r '.text')"
    assert_equals "$name" "$original" "$restored"
}

check_json_roundtrip "特殊文字なしの本文を正しく組み立てられる" \
    ':x: バックアップに失敗しました'
check_json_roundtrip 'ダブルクォート(")を含む本文を正しくエスケープする' \
    'tar: 対象 "public html" を開けません'
check_json_roundtrip 'バックスラッシュ(\)を含む本文を正しくエスケープする' \
    'パス C:\backup\html の検証に失敗'
check_json_roundtrip "改行を含む本文を正しくエスケープする" \
    "$(printf 'バックアップ失敗\n終了コード: 2')"
check_json_roundtrip "タブを含む本文を正しくエスケープする" \
    "$(printf 'サーバー\tweb01\tNG')"

# --- 回帰テスト: 旧方式(文字列連結)なら壊れることを確認する ---
#   なぜこれをテストに入れるか:
#   「直したはずのバグが将来また戻ってこないか」を見張るのがこのテストの役割。
#   旧方式が壊れることを明示しておくと、うっかり旧方式に書き戻したときに
#   「なぜjqを使っているのか」を思い出せる。
old_style_payload="{\"text\": \"$(printf 'tar: 対象 "public html" を開けません')\"}"
if printf '%s' "$old_style_payload" | jq empty > /dev/null 2>&1; then
    echo "  [FAIL] 旧方式(文字列連結)がダブルクォートで壊れることの確認"
    TEST_FAIL=$((TEST_FAIL + 1))
else
    echo "  [PASS] 旧方式(文字列連結)はダブルクォートで壊れる(改善前の再現)"
    TEST_PASS=$((TEST_PASS + 1))
fi

#======================================================================
echo ""
echo "[5] Slack通知 ops_notify_slack"
#======================================================================

# --- 5-1 通知が無効なら、送信せず正常終了(戻り値0) ---
OPS_SLACK_ENABLED="false"
OPS_SLACK_DRY_RUN="false"
OPS_SLACK_WEBHOOK_URL=""
assert_status "OPS_SLACK_ENABLED=false なら送信せず戻り値0" 0 ops_notify_slack "通知テスト"

# --- 5-2 ドライランなら送信せず、送る予定のJSONを出力する ---
OPS_SLACK_ENABLED="true"
OPS_SLACK_DRY_RUN="true"
dry_out="$(ops_notify_slack 'ドライラン "テスト"')"
assert_contains "ドライランでは送信予定のJSONが出力される" \
    '{"text":"ドライラン \"テスト\""}' "$dry_out"
assert_status "ドライランの戻り値は0" 0 ops_notify_slack "ドライラン"

# --- 5-3 URL未設定なら戻り値2(設定不足) ---
OPS_SLACK_DRY_RUN="false"
OPS_SLACK_WEBHOOK_URL=""
assert_status "Webhook URL未設定なら戻り値2(設定不足)" 2 ops_notify_slack "通知テスト"

# 後続テストのため通知を無効に戻す
OPS_SLACK_ENABLED="false"

#======================================================================
echo ""
echo "[6] 設定ファイルの読み込み ops_load_config"
#======================================================================

# --- 6-1 正常な設定ファイルを読み込むと、変数が使えるようになる ---
cfg_ok="${TEST_TMP_DIR}/ok.conf"
cat > "$cfg_ok" <<'EOF'
TEST_VALUE="読み込み成功"
TEST_NUMBER=42
EOF
chmod 600 "$cfg_ok"

assert_status "正常な設定ファイルの読み込みは戻り値0" 0 ops_load_config "$cfg_ok"

# assert_status はコマンドを実行するだけなので、値の確認は改めて読み込んで行う
ops_load_config "$cfg_ok" > /dev/null 2>&1
assert_equals "設定ファイルの値が変数として使える" "読み込み成功" "${TEST_VALUE:-未設定}"
assert_equals "設定ファイルの数値も読み込める" "42" "${TEST_NUMBER:-未設定}"

# --- 6-2 存在しないファイルは戻り値1。しかも呼び出し側は生き残る ---
#   ライブラリが内部で exit していたら、この行以降は実行されない。
#   「テストが最後まで到達すること」自体が exit していない証拠になる。
assert_status "存在しない設定ファイルは戻り値1(exitしない)" 1 \
    ops_load_config "${TEST_TMP_DIR}/does-not-exist.conf"

# --- 6-3 権限が緩い設定ファイルは警告を出すが、読み込みは成功する ---
cfg_loose="${TEST_TMP_DIR}/loose.conf"
echo 'LOOSE_VALUE="ゆるい権限"' > "$cfg_loose"
chmod 644 "$cfg_loose"
# WARNレベルは標準出力に出るため、ここは標準出力をそのまま受け取る
# (標準エラー出力に出るのは ERROR レベルだけ、という設計にしているため)
loose_warn="$(ops_load_config "$cfg_loose")"
assert_contains "権限が緩い設定ファイルには警告を出す" "chmod 600" "$loose_warn"
assert_status "権限が緩くても読み込み自体は成功する(戻り値0)" 0 ops_load_config "$cfg_loose"

#======================================================================
echo ""
echo "[7] 前提コマンドの確認 ops_require_commands"
#======================================================================

assert_status "存在するコマンドだけなら戻り値0" 0 ops_require_commands date printf
assert_status "存在しないコマンドが混ざると戻り値1" 1 ops_require_commands date no_such_command_xyz

# --- 足りないコマンドを「すべて」列挙すること ---
#   1つ見つけて即座に止めると、直して再実行するたびに次の不足が判明し
#   二度手間になる。まとめて教えるほうが親切という設計判断のテスト。
missing_msg="$(ops_require_commands no_such_cmd_aaa no_such_cmd_bbb 2>&1 1> /dev/null)"
assert_contains "不足コマンドを1つ目まで列挙する" "no_such_cmd_aaa" "$missing_msg"
assert_contains "不足コマンドを2つ目まで列挙する" "no_such_cmd_bbb" "$missing_msg"

#======================================================================
echo ""
echo "[8] ライブラリとしての行儀(副作用がないこと)"
#======================================================================

# --- 8-1 二重に source しても壊れないこと ---
# shellcheck source=./opslib.sh
source "${SCRIPT_DIR}/opslib.sh"
assert_equals "二重に source してもバージョンが保たれる" "1.0.0" "$(ops_lib_version)"

# --- 8-2 呼び出し側のシェルオプションを勝手に変えないこと ---
#   $- には有効なシェルオプションの文字が入っている(u=set -u, e=set -e など)。
#   ライブラリを読み込む前後で変化していなければ、副作用がないと言える。
opts_before="$-"
# shellcheck source=./opslib.sh
source "${SCRIPT_DIR}/opslib.sh"
opts_after="$-"
assert_equals "source してもシェルオプション(\$-)が変化しない" "$opts_before" "$opts_after"

# --- 8-3 直接実行された場合は使い方を表示して終了すること ---
assert_status "直接実行すると戻り値1で使い方を表示する" 1 bash "${SCRIPT_DIR}/opslib.sh"

#======================================================================
# 結果サマリ
#======================================================================
echo ""
echo "==================================================================="
echo " テスト結果: 成功 ${TEST_PASS}件 / 失敗 ${TEST_FAIL}件"
echo "==================================================================="

if [ "$TEST_FAIL" -gt 0 ]; then
    exit 1
fi

exit 0
