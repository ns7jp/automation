#!/bin/bash
#===============================================================================
# ex09 の採点テスト
#   check.sh から呼び出される。単体で直接実行するものではない。
#===============================================================================

# shellcheck source=../../lib/harness.sh
source "${EX_LIB}/harness.sh"

require_target
assert_no_syntax_error

#-------------------------------------------------------------------------------
# 本物の curl を動かすと外部のサーバーへ通信してしまうため、
# 呼び出し内容を記録するだけのダミーコマンドに差し替える。
#-------------------------------------------------------------------------------
enable_stubs curl

# 採点で使う送信先(実在しないダミーのURL)
HOOK_URL="https://hooks.example.com/services/T000/B000/XXXXXXXX"

# hostname の値をそのまま正規表現に埋めると「.」が誤動作するためエスケープする
HOST_NAME="$(hostname)"
HOST_PATTERN="${HOST_NAME//./\\.}"

#-------------------------------------------------------------------------------
describe "異常系: 引数なしで実行したとき"
#-------------------------------------------------------------------------------
export WEBHOOK_URL="$HOOK_URL"
reset_stub_log
run_target

hint "引数の個数は \$# で調べます。2個でなければ exit 1 で終了してください。"
assert_status 1 "引数なしで実行すると終了ステータス1で終わる"

hint "使い方は usage >&2 のように標準エラー出力へ出します。"
assert_stderr_contains "使い方" "使い方のメッセージを標準エラー出力に表示する"

#-------------------------------------------------------------------------------
describe "異常系: 第1引数が success / failure 以外のとき"
#-------------------------------------------------------------------------------
reset_stub_log
run_target warning "テスト通知"

hint "case \"\$STATUS\" in success) ... ;; failure) ... ;; *) exit 1 ;; esac で弾きます。"
assert_status 1 "第1引数が success / failure 以外なら終了ステータス1で終わる"

hint "種別が違うときも、引数不足と同じように使い方を標準エラー出力へ出します。"
assert_stderr_contains "使い方" "第1引数が不正なとき、使い方のメッセージを標準エラー出力に表示する"

#-------------------------------------------------------------------------------
describe "正常系: WEBHOOK_URL が未設定のとき"
#-------------------------------------------------------------------------------
unset WEBHOOK_URL
reset_stub_log
run_target failure "バックアップに失敗しました"

hint "通知できないことは「処理が失敗したこと」ではありません。exit 0 で終わります。"
assert_status 0 "WEBHOOK_URL が未設定なら終了ステータス0で終わる"

hint "メッセージは「WEBHOOK_URL が未設定のため通知をスキップします」と一字一句同じにします。"
assert_stdout_contains "WEBHOOK_URL が未設定のため通知をスキップします" \
    "WEBHOOK_URL が未設定なら、スキップしたことを標準出力に表示する"

hint "[[ -z \"\${WEBHOOK_URL:-}\" ]] の判定を curl より前に置いて、その場で exit 0 してください。"
assert_stub_not_called curl "." "WEBHOOK_URL が未設定なら curl を実行しない"

#-------------------------------------------------------------------------------
describe "正常系: failure を通知したとき"
#-------------------------------------------------------------------------------
export WEBHOOK_URL="$HOOK_URL"
reset_stub_log
run_target failure "バックアップに失敗しました"

hint "送信できたときは exit 0 です。"
assert_status 0 "通知に成功すると終了ステータス0で終わる"

hint "送信先は環境変数 WEBHOOK_URL の値です。curl の最後の引数に \"\$WEBHOOK_URL\" を渡します。"
assert_stub_called curl "hooks\.example\.com/services/T000/B000/XXXXXXXX" \
    "WEBHOOK_URL 宛に curl で送信する"

hint "-H \"Content-Type: application/json\" を付けて、本文がJSONであることを伝えます。"
assert_stub_called curl "Content-Type: *application/json" \
    "Content-Type: application/json ヘッダーを付けて送信する"

hint "ラベルの後ろは半角スペース、ホスト名の後ろは半角コロン+半角スペースで区切ります。"
assert_stub_called curl \
    "\\{\"text\":\"\\[FAILURE\\] ${HOST_PATTERN}: バックアップに失敗しました\"\\}" \
    '本文を {"text":"[FAILURE] <ホスト名>: <メッセージ>"} の形式で送信する'

hint "送信後に「通知を送信しました: 」に続けて同じ内容を標準出力へ表示します。"
assert_stdout_contains "通知を送信しました: [FAILURE] ${HOST_NAME}: バックアップに失敗しました" \
    "送信できたことを標準出力に表示する"

#-------------------------------------------------------------------------------
describe "正常系: success を通知したとき"
#-------------------------------------------------------------------------------
reset_stub_log
run_target success "バックアップが完了しました"

hint "success のときのラベルは [SUCCESS] です。大文字で書きます。"
assert_stub_called curl "\[SUCCESS\] ${HOST_PATTERN}: バックアップが完了しました" \
    "success のときは本文のラベルを [SUCCESS] にする"

#-------------------------------------------------------------------------------
describe "正常系: メッセージにダブルクォートが含まれるとき"
#-------------------------------------------------------------------------------
reset_stub_log
run_target failure 'tar が "backup.tar.gz" の作成に失敗しました'

hint "\${MESSAGE//\\\"/\\\\\\\"} で、メッセージ中の \" をすべて \\\" に置換できます。"
assert_stub_called curl '\\"backup\.tar\.gz\\"' \
    'メッセージ中のダブルクォートを \" にエスケープして送信する'

#-------------------------------------------------------------------------------
describe "異常系: curl の送信が失敗したとき"
#-------------------------------------------------------------------------------
export STUB_FAIL_CMDS="curl"
reset_stub_log
run_target failure "バックアップに失敗しました"

hint "if ! curl ...; then でcurlの終了ステータスを見て、失敗なら exit 1 にします。"
assert_status 1 "curl が失敗すると終了ステータス1で終わる"

hint "メッセージは「エラー: 通知の送信に失敗しました」と一字一句同じにし、>&2 を付けます。"
assert_stderr_contains "エラー: 通知の送信に失敗しました" \
    "curl が失敗したらエラーメッセージを標準エラー出力に表示する"

unset STUB_FAIL_CMDS

finish
