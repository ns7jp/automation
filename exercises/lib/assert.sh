#!/bin/bash
#===============================================================================
# assert.sh — 演習の自動採点で使う「判定関数」ライブラリ
#
# 概要:
#   各演習の tests/test.sh から読み込まれ、「期待どおりに動いたか」を
#   1項目ずつ判定して、その場で合否を画面に表示する。
#
#   このファイル自体を編集する必要はありません。
#   仕組みを知りたい場合は docs/04-self-check-guide.md を参照してください。
#
# 提供する主な関数:
#   describe <見出し>                        テスト項目のグループ見出しを表示
#   hint <文字列>                            次の1項目が失敗したときに出すヒント
#   assert_status <期待値> <説明>            直前の実行の終了ステータスを判定
#   assert_eq <期待値> <実際値> <説明>       文字列の完全一致を判定
#   assert_stdout_contains <部分文字列> <説明>
#   assert_stdout_matches <正規表現> <説明>
#   assert_output_contains <部分文字列> <説明>      (標準出力+標準エラー)
#   assert_output_not_contains <部分文字列> <説明>
#   assert_stderr_contains <部分文字列> <説明>
#   assert_file_exists <パス> <説明>
#   assert_file_contains <パス> <正規表現> <説明>
#   assert_file_not_contains <パス> <正規表現> <説明>
#   assert_file_count <グロブ> <期待件数> <説明>
#   assert_stub_called <コマンド名> <正規表現> <説明>
#   assert_stub_not_called <コマンド名> <正規表現> <説明>
#   assert_cmd <説明> <コマンド...>          コマンドの終了ステータスが0なら合格
#   skip <理由>                              判定できない項目を「スキップ」として記録
#   finish                                   集計を表示して終了(合格なら0)
#===============================================================================

# 二重読み込み防止
if [[ -n "${_ASSERT_SH_LOADED:-}" ]]; then
    return 0
fi
_ASSERT_SH_LOADED=1

#-------------------------------------------------------------------------------
# 集計用のカウンタ
#-------------------------------------------------------------------------------
_PASS=0
_FAIL=0
_SKIP=0
_CASE_NO=0
_NEXT_HINT=""

#-------------------------------------------------------------------------------
# 色の設定
#   画面(端末)に直接出力しているときだけ色を付ける。
#   ログファイルへのリダイレクト時やCI上では色コードを付けない。
#-------------------------------------------------------------------------------
if [[ -t 1 ]]; then
    _C_RED=$'\033[31m'
    _C_GREEN=$'\033[32m'
    _C_YELLOW=$'\033[33m'
    _C_GRAY=$'\033[90m'
    _C_BOLD=$'\033[1m'
    _C_OFF=$'\033[0m'
else
    _C_RED="" _C_GREEN="" _C_YELLOW="" _C_GRAY="" _C_BOLD="" _C_OFF=""
fi

#-------------------------------------------------------------------------------
# 内部関数: 値を見やすく整形して表示する
#   1行なら「      期待: 値」、複数行なら折り返してインデント表示する。
#-------------------------------------------------------------------------------
_show_value() {
    local label="$1"
    local value="$2"

    if [[ -z "$value" ]]; then
        printf '      %s: %s(空)%s\n' "$label" "$_C_GRAY" "$_C_OFF"
        return 0
    fi

    if [[ "$value" != *$'\n'* ]]; then
        printf '      %s: %s\n' "$label" "$value"
        return 0
    fi

    printf '      %s:\n' "$label"
    # 長すぎる出力は先頭20行だけ表示する(画面が埋まるのを防ぐため)
    local line count=0
    while IFS= read -r line; do
        count=$((count + 1))
        if [[ "$count" -gt 20 ]]; then
            printf '        %s... (以下省略)%s\n' "$_C_GRAY" "$_C_OFF"
            break
        fi
        printf '        | %s\n' "$line"
    done <<< "$value"
}

#-------------------------------------------------------------------------------
# 内部関数: 1項目の合格/不合格を表示する
#-------------------------------------------------------------------------------
_ok() {
    local desc="$1"
    _CASE_NO=$((_CASE_NO + 1))
    _PASS=$((_PASS + 1))
    printf '  %s✓%s [%d] %s\n' "$_C_GREEN" "$_C_OFF" "$_CASE_NO" "$desc"
    _NEXT_HINT=""
}

_ng() {
    local desc="$1"
    local expected="${2-}"
    local actual="${3-}"
    _CASE_NO=$((_CASE_NO + 1))
    _FAIL=$((_FAIL + 1))
    printf '  %s✗%s [%d] %s\n' "$_C_RED" "$_C_OFF" "$_CASE_NO" "$desc"
    if [[ $# -ge 2 ]]; then
        _show_value "期待" "$expected"
        _show_value "実際" "$actual"
    fi
    if [[ -n "$_NEXT_HINT" ]]; then
        printf '      %sヒント: %s%s\n' "$_C_YELLOW" "$_NEXT_HINT" "$_C_OFF"
    fi
    _NEXT_HINT=""
}

#-------------------------------------------------------------------------------
# describe: テスト項目のグループ見出しを表示する
#-------------------------------------------------------------------------------
describe() {
    printf '  %s— %s —%s\n' "$_C_GRAY" "$1" "$_C_OFF"
}

#-------------------------------------------------------------------------------
# hint: 「次の1項目」が不合格だった場合に表示するヒントを登録する
#   使い方:
#     hint "exit 1 を書き忘れていませんか?"
#     assert_status 1 "引数なしのときは終了ステータス1"
#-------------------------------------------------------------------------------
hint() {
    _NEXT_HINT="$1"
}

#-------------------------------------------------------------------------------
# skip: 環境の都合で判定できない項目を「スキップ」として記録する
#   例: shellcheck が未インストールの環境での静的解析チェック
#-------------------------------------------------------------------------------
skip() {
    local reason="$1"
    _CASE_NO=$((_CASE_NO + 1))
    _SKIP=$((_SKIP + 1))
    printf '  %s-%s [%d] スキップ: %s\n' "$_C_YELLOW" "$_C_OFF" "$_CASE_NO" "$reason"
    _NEXT_HINT=""
}

#===============================================================================
# 判定関数
#===============================================================================

# 終了ステータスを判定する($LAST_STATUS は run_target が設定する)
assert_status() {
    local expected="$1" desc="$2"
    local actual="${LAST_STATUS:-未実行}"

    if [[ "$actual" == "124" && "$expected" != "124" ]]; then
        _ng "$desc" "$expected" "タイムアウト(実行が終わらなかった)"
        return 0
    fi
    if [[ "$actual" == "$expected" ]]; then
        _ok "$desc"
    else
        _ng "$desc" "終了ステータス $expected" "終了ステータス $actual"
    fi
    return 0
}

# 文字列の完全一致
assert_eq() {
    local expected="$1" actual="$2" desc="$3"
    if [[ "$actual" == "$expected" ]]; then
        _ok "$desc"
    else
        _ng "$desc" "$expected" "$actual"
    fi
    return 0
}

# 標準出力に指定した文字列が含まれるか
assert_stdout_contains() {
    local needle="$1" desc="$2"
    if [[ "${LAST_STDOUT:-}" == *"$needle"* ]]; then
        _ok "$desc"
    else
        _ng "$desc" "「${needle}」を含む出力" "${LAST_STDOUT:-}"
    fi
    return 0
}

# 標準出力が正規表現にマッチするか
assert_stdout_matches() {
    local pattern="$1" desc="$2"
    if [[ "${LAST_STDOUT:-}" =~ $pattern ]]; then
        _ok "$desc"
    else
        _ng "$desc" "正規表現 ${pattern} にマッチする出力" "${LAST_STDOUT:-}"
    fi
    return 0
}

# 標準出力+標準エラーに指定した文字列が含まれるか
assert_output_contains() {
    local needle="$1" desc="$2"
    if [[ "${LAST_OUTPUT:-}" == *"$needle"* ]]; then
        _ok "$desc"
    else
        _ng "$desc" "「${needle}」を含む出力" "${LAST_OUTPUT:-}"
    fi
    return 0
}

# 標準出力+標準エラーに指定した文字列が「含まれない」こと
assert_output_not_contains() {
    local needle="$1" desc="$2"
    if [[ "${LAST_OUTPUT:-}" != *"$needle"* ]]; then
        _ok "$desc"
    else
        _ng "$desc" "「${needle}」を含まない出力" "${LAST_OUTPUT:-}"
    fi
    return 0
}

# 標準エラー出力に指定した文字列が含まれるか
assert_stderr_contains() {
    local needle="$1" desc="$2"
    if [[ "${LAST_STDERR:-}" == *"$needle"* ]]; then
        _ok "$desc"
    else
        _ng "$desc" "標準エラー出力に「${needle}」" "${LAST_STDERR:-}"
    fi
    return 0
}

# 標準出力+標準エラーが正規表現にマッチするか
assert_output_matches() {
    local pattern="$1" desc="$2"
    if [[ "${LAST_OUTPUT:-}" =~ $pattern ]]; then
        _ok "$desc"
    else
        _ng "$desc" "正規表現 ${pattern} にマッチする出力" "${LAST_OUTPUT:-}"
    fi
    return 0
}

# ファイルが存在するか
assert_file_exists() {
    local path="$1" desc="$2"
    if [[ -e "$path" ]]; then
        _ok "$desc"
    else
        _ng "$desc" "ファイルが存在する: ${path}" "存在しない"
    fi
    return 0
}

# ファイルが存在しないこと
assert_file_not_exists() {
    local path="$1" desc="$2"
    if [[ ! -e "$path" ]]; then
        _ok "$desc"
    else
        _ng "$desc" "ファイルが存在しない: ${path}" "存在する"
    fi
    return 0
}

# ファイルの中身が正規表現(grep -E)にマッチするか
assert_file_contains() {
    local path="$1" pattern="$2" desc="$3"
    if [[ ! -f "$path" ]]; then
        _ng "$desc" "ファイル ${path} が存在し「${pattern}」を含む" "ファイルが存在しない"
        return 0
    fi
    if grep -Eq -- "$pattern" "$path"; then
        _ok "$desc"
    else
        _ng "$desc" "「${pattern}」にマッチする行を含む" "$(head -n 20 "$path")"
    fi
    return 0
}

# ファイルの中身が正規表現にマッチ「しない」こと
assert_file_not_contains() {
    local path="$1" pattern="$2" desc="$3"
    if [[ ! -f "$path" ]]; then
        _ng "$desc" "ファイル ${path} が存在する" "ファイルが存在しない"
        return 0
    fi
    if grep -Eq -- "$pattern" "$path"; then
        _ng "$desc" "「${pattern}」にマッチする行を含まない" "$(grep -E -- "$pattern" "$path" | head -n 5)"
    else
        _ok "$desc"
    fi
    return 0
}

# グロブにマッチするファイル数を判定する
#   例: assert_file_count "$WORKDIR/backup/*.tar.gz" 3 "世代が3つ残る"
assert_file_count() {
    local pattern="$1" expected="$2" desc="$3"
    local -a matched=()
    local f
    # グロブ展開(マッチしない場合に文字列がそのまま残らないよう存在チェックする)
    for f in $pattern; do
        [[ -e "$f" ]] && matched+=("$f")
    done
    local actual="${#matched[@]}"
    if [[ "$actual" -eq "$expected" ]]; then
        _ok "$desc"
    else
        _ng "$desc" "${expected}件" "${actual}件${matched[*]:+ (${matched[*]##*/})}"
    fi
    return 0
}

# ダミーコマンド(スタブ)が呼ばれたことを判定する
#   例: assert_stub_called useradd "sato_k" "useradd で sato_k を作成している"
assert_stub_called() {
    local cmd="$1" pattern="$2" desc="$3"
    local log="${STUB_LOG:-}"
    if [[ -z "$log" || ! -f "$log" ]]; then
        _ng "$desc" "${cmd} が呼ばれる" "ダミーコマンドが1回も呼ばれていない"
        return 0
    fi
    if grep -E -- "^${cmd} " "$log" | grep -Eq -- "$pattern"; then
        _ok "$desc"
    else
        _ng "$desc" "${cmd} の実行(条件: ${pattern})" "$(cat "$log")"
    fi
    return 0
}

# ダミーコマンドが呼ばれて「いない」ことを判定する(ドライラン検証などで使う)
assert_stub_not_called() {
    local cmd="$1" pattern="$2" desc="$3"
    local log="${STUB_LOG:-}"
    if [[ -z "$log" || ! -f "$log" ]]; then
        _ok "$desc"
        return 0
    fi
    if grep -E -- "^${cmd} " "$log" | grep -Eq -- "$pattern"; then
        _ng "$desc" "${cmd} が実行されない" "$(grep -E -- "^${cmd} " "$log" | head -n 5)"
    else
        _ok "$desc"
    fi
    return 0
}

# 任意のコマンドを実行し、終了ステータス0なら合格
#   例: assert_cmd "bash構文エラーがない" bash -n "$TARGET"
assert_cmd() {
    local desc="$1"
    shift
    local out
    if out=$("$@" 2>&1); then
        _ok "$desc"
    else
        _ng "$desc" "コマンド成功: $*" "${out:-(出力なし)}"
    fi
    return 0
}

#===============================================================================
# finish: 集計結果を表示して終了する
#   合格(不合格0件)なら終了ステータス0、1件でも不合格なら1を返す。
#   check.sh はこの終了ステータスで演習ごとの合否を判定している。
#===============================================================================
finish() {
    local total=$((_PASS + _FAIL))
    if [[ "$_FAIL" -eq 0 ]]; then
        printf '  %s結果: %d/%d 合格%s' "$_C_GREEN$_C_BOLD" "$_PASS" "$total" "$_C_OFF"
    else
        printf '  %s結果: %d/%d 合格%s' "$_C_RED$_C_BOLD" "$_PASS" "$total" "$_C_OFF"
    fi
    if [[ "$_SKIP" -gt 0 ]]; then
        printf ' (スキップ %d件)' "$_SKIP"
    fi
    printf '\n'

    if [[ "$_FAIL" -eq 0 ]]; then
        exit 0
    fi
    exit 1
}
