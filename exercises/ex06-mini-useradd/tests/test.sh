#!/bin/bash
#===============================================================================
# ex06 の採点テスト
#   check.sh から呼び出される。単体で直接実行するものではない。
#===============================================================================

# shellcheck source=../../lib/harness.sh
source "${EX_LIB}/harness.sh"

require_target
assert_no_syntax_error

# 危険なコマンドをダミー(スタブ)に差し替える。
# 本物の useradd は動かないので、採点でアカウントが増えることはない。
enable_stubs useradd groupadd chpasswd chage getent

#-------------------------------------------------------------------------------
# 採点用のCSVを作業ディレクトリに用意する
#-------------------------------------------------------------------------------
cat > users.csv <<'CSV_EOF'
氏名,ユーザー名,部署,初期パスワード
山田 太郎,yamada_t,sales,InitPass01
佐藤 花子,sato_h,sales,InitPass02
鈴木 一郎,suzuki_i,dev,InitPass03
CSV_EOF

cat > bad_name.csv <<'CSV_EOF'
氏名,ユーザー名,部署,初期パスワード
高橋 次郎,Takahashi.J,dev,InitPass04
田中 三郎,tanaka_s,dev,InitPass05
CSV_EOF

cat > one.csv <<'CSV_EOF'
氏名,ユーザー名,部署,初期パスワード
山田 太郎,yamada_t,sales,InitPass01
CSV_EOF

#-------------------------------------------------------------------------------
# root で採点しているかどうかを調べる。
#   このスクリプトは仕様上 root 以外では権限チェックで止まるため、
#   一般ユーザーで採点している場合はアカウント作成部分の判定を省略する。
#-------------------------------------------------------------------------------
IS_ROOT="no"
if [[ "$EUID" -eq 0 ]]; then
    IS_ROOT="yes"
fi
SKIP_REASON="一般ユーザーで採点しているため省略します (sudo ./check.sh 06 で全項目を判定できます)"

#-------------------------------------------------------------------------------
describe "異常系: 引数の指定が正しくないとき"
#-------------------------------------------------------------------------------
run_target

hint "-f が指定されていないときは、エラーと使い方を標準エラー出力に出して exit 1 で終わります。"
assert_status 1 "-f を指定せずに実行すると終了ステータス1で終わる"

hint "使い方の表示は usage >&2 のように標準エラー出力へ向けます。"
assert_stderr_contains "使い方" "-f が未指定のとき、使い方を標準エラー出力に表示する"

run_target -f nosuch.csv

hint "ファイルの有無は [[ ! -f \"\$CSV_FILE\" ]] で判定します(ex02の復習)。"
assert_status 1 "存在しないCSVファイルを指定すると終了ステータス1で終わる"

hint "メッセージの末尾には、指定されたパスをそのまま付けます。"
assert_stderr_contains "エラー: CSVファイルが見つかりません: nosuch.csv" \
    "見つからないCSVのパスを添えてエラーを標準エラー出力に表示する"

#-------------------------------------------------------------------------------
describe "正常系: ヘルプを表示したとき"
#-------------------------------------------------------------------------------
run_target -h

hint "ヘルプは利用者が求めた出力なので、成功(0)で終了します。"
assert_status 0 "-h を指定すると終了ステータス0で終わる"

hint "ヘルプは標準出力に出します(>&2 を付けない)。"
assert_stdout_contains "使い方" "-h で使い方を標準出力に表示する"

run_target --help

hint "--help は -h に変換してから getopts に渡します(ex05の復習)。"
assert_status 0 "--help でも終了ステータス0で終わる"

#-------------------------------------------------------------------------------
describe "実行権限のチェック"
#-------------------------------------------------------------------------------
export STUB_EXISTING_USERS="sato_h"
export STUB_EXISTING_GROUPS="sales"
reset_stub_log
run_target -f users.csv

if [[ "$IS_ROOT" == "yes" ]]; then
    note "root権限で採点しているため、権限チェックで止まらないことを確認します。"

    hint "実効ユーザーIDが0のとき(root)は、権限エラーを出さずに処理を続けます。"
    assert_output_not_contains "root権限で実行してください" \
        "root で実行したときは権限エラーを出さない"

    hint "最後まで処理できて失敗が0件なら exit 0 です。"
    assert_status 0 "root で実行したときは最後まで処理して終了ステータス0で終わる"
else
    note "一般ユーザーで採点しているため、権限チェックで止まることを確認します。"

    hint "root以外のときは、処理を始める前にエラーを出して exit 1 で終わります。"
    assert_status 1 "root以外で実行すると終了ステータス1で終わる"

    hint "メッセージは仕様どおりの文言にしてください。"
    assert_stderr_contains "エラー: このスクリプトはroot権限で実行してください。" \
        "root以外のときは権限エラーを標準エラー出力に表示する"
fi

hint "実効ユーザーIDは \$EUID で取り出せます。id -u でも構いません。"
assert_file_contains "$TARGET" 'EUID|id -u' "root権限の判定に \$EUID または id -u を使っている"

#-------------------------------------------------------------------------------
describe "正常系: CSVを読み込んでユーザーを作成する"
#-------------------------------------------------------------------------------
if [[ "$IS_ROOT" != "yes" ]]; then
    skip "アカウント作成の判定は${SKIP_REASON}"
else
    export STUB_EXISTING_USERS="sato_h"
    export STUB_EXISTING_GROUPS="sales"
    reset_stub_log
    run_target -f users.csv

    hint "失敗が0件なら exit 0 です。"
    assert_status 0 "失敗が0件のときは終了ステータス0で終わる"

    hint "カウンタはループの外に残す必要があります。パイプではなく < <(...) で渡します。"
    assert_stdout_contains "成功: 2件 / スキップ: 1件 / 失敗: 0件" \
        "成功・スキップ・失敗の件数を集計して表示する"

    hint "useradd -m -c \"<氏名>\" -g \"<部署>\" -s /bin/bash \"<ユーザー名>\" の形で実行します。"
    assert_stub_called useradd "-c 山田 太郎.*-g sales.*yamada_t" \
        "useradd に氏名(-c)と部署(-g)を渡してユーザーを作成する"

    hint "getent passwd で見つかったユーザーはスキップします。"
    assert_stdout_contains "SKIP ユーザー sato_h は既に存在するためスキップしました" \
        "既存ユーザーはスキップして SKIP と記録する"

    hint "スキップした行では useradd を実行してはいけません(べき等性)。"
    assert_stub_not_called useradd "sato_h" "既存ユーザーに対しては useradd を実行しない"

    hint "getent group で見つからないグループだけ groupadd で作ります。"
    assert_stub_called groupadd "dev" "存在しないグループ dev を groupadd で作成する"

    hint "既にあるグループを作り直してはいけません(べき等性)。"
    assert_stub_not_called groupadd "sales" "既に存在するグループ sales は作成しない"

    hint "echo \"<ユーザー名>:<初期パスワード>\" | chpasswd で設定します。"
    assert_file_contains "$STUB_LOG" '^chpasswd' "chpasswd で初期パスワードを設定する"

    hint "chage -d 0 <ユーザー名> で初回ログイン時のパスワード変更を強制します。"
    assert_stub_called chage "-d 0 yamada_t" "chage -d 0 で初回ログイン時のパスワード変更を強制する"

    hint "パスワードはパイプで chpasswd に渡します。画面に出してはいけません。"
    assert_output_not_contains "InitPass01" "初期パスワードを画面に出力しない"
fi

#-------------------------------------------------------------------------------
describe "正常系: ドライラン(-n)のとき"
#-------------------------------------------------------------------------------
if [[ "$IS_ROOT" != "yes" ]]; then
    skip "ドライランの判定は${SKIP_REASON}"
else
    export STUB_EXISTING_USERS="sato_h"
    export STUB_EXISTING_GROUPS="sales"
    reset_stub_log
    run_target -f users.csv -n

    hint "ドライランは異常ではないので exit 0 です。"
    assert_status 0 "ドライランでも終了ステータス0で終わる"

    hint "実行するはずだった内容を [dry-run] 付きで表示します。"
    assert_stdout_contains "[dry-run]" "ドライランでは [dry-run] 付きのログを表示する"

    hint "ドライランでは、危険なコマンドに到達する前に continue で次の行へ進みます。"
    assert_file_not_contains "$STUB_LOG" '^(useradd|groupadd|chpasswd|chage)' \
        "ドライランでは useradd / groupadd / chpasswd / chage を1つも実行しない"
fi

#-------------------------------------------------------------------------------
describe "異常系: 不正なユーザー名の行があるとき"
#-------------------------------------------------------------------------------
if [[ "$IS_ROOT" != "yes" ]]; then
    skip "不正なユーザー名の判定は${SKIP_REASON}"
else
    export STUB_EXISTING_USERS=""
    export STUB_EXISTING_GROUPS="dev"
    reset_stub_log
    run_target -f bad_name.csv

    hint "^[a-z_][a-z0-9_-]*\$ に一致しないユーザー名は作成せず、失敗として数えます。"
    assert_stdout_contains "ERROR 不正なユーザー名のためスキップ: Takahashi.J" \
        "不正なユーザー名の行はERRORとして記録する"

    hint "1行の失敗で全体を止めず、continue で次の行へ進みます。"
    assert_stub_called useradd "tanaka_s" "不正な行の次の行は、そのまま処理を続ける"

    hint "不正な行は「失敗」に数えます(スキップではありません)。"
    assert_stdout_contains "成功: 1件 / スキップ: 0件 / 失敗: 1件" \
        "不正なユーザー名の行だけを失敗件数に数える"
fi

#-------------------------------------------------------------------------------
describe "異常系: useradd が失敗したとき"
#-------------------------------------------------------------------------------
if [[ "$IS_ROOT" != "yes" ]]; then
    skip "useradd 失敗時の判定は${SKIP_REASON}"
else
    export STUB_EXISTING_USERS=""
    export STUB_EXISTING_GROUPS="sales"
    export STUB_FAIL_CMDS="useradd"
    reset_stub_log
    run_target -f one.csv

    hint "if ! useradd ...; then で失敗を受け止め、ERROR として記録します。"
    assert_stdout_contains "ERROR ユーザー yamada_t の作成に失敗しました" \
        "useradd の失敗をERRORとして記録する"

    hint "失敗が1件以上あれば、呼び出し元に知らせるため exit 1 で終わります。"
    assert_status 1 "失敗が1件以上あるときは終了ステータス1で終わる"

    export STUB_FAIL_CMDS=""
fi

finish
