#!/bin/bash
#===============================================================================
# ex21 の採点テスト
#   check.sh から呼び出される。単体で直接実行するものではない。
#
#   使い捨ての作業ディレクトリの中に、検査対象となる「サンプルの
#   プロジェクト一式」を作ってから採点する。実際のサーバーや
#   ネットワークは一切使わない。
#===============================================================================

# shellcheck source=../../lib/harness.sh
source "${EX_LIB}/harness.sh"

require_target
assert_no_syntax_error

#-------------------------------------------------------------------------------
# 検査対象となるサンプルプロジェクトを作る関数
#   引数で渡したディレクトリの下に app/ と scripts/ を作り直す。
#   scripts/ に置くスクリプトは、shellcheck を通しても警告が出ない内容にする
#   (採点環境に shellcheck がある場合、T5 が合格になるようにするため)。
#-------------------------------------------------------------------------------
make_project() {
    local dest="$1"

    rm -rf "${dest:?}/app" "${dest:?}/scripts"
    mkdir -p "${dest}/app/css" "${dest}/scripts"

    cat > "${dest}/app/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="utf-8">
  <title>社内ポータル</title>
</head>
<body>
  <h1>社内ポータル</h1>
</body>
</html>
EOF

    cat > "${dest}/app/css/style.css" <<'EOF'
body { font-family: sans-serif; }
EOF

    cat > "${dest}/scripts/deploy.sh" <<'EOF'
#!/bin/bash
set -eu
echo "deploy を実行しました"
EOF

    cat > "${dest}/scripts/build.sh" <<'EOF'
#!/bin/bash
set -eu
echo "build を実行しました"
EOF
}

#-------------------------------------------------------------------------------
describe "正常系: 問題のないプロジェクトを検査したとき"
#-------------------------------------------------------------------------------
make_project "${WORKDIR}/proj"
run_target proj

hint "失敗が1件も無いときは exit 0 で終わります。CIはこの終了ステータスだけを見て緑と赤を決めます。"
assert_status 0 "失敗が無いときは終了ステータス0で終わる"

PASS_LINES="$(grep -c '^\[PASS\]' <<< "${LAST_STDOUT:-}" || true)"

hint "T1〜T4 の4つのテストすべてで pass を呼んでください。今回数えられた [PASS] の行数は ${PASS_LINES} 件でした。"
assert_cmd "問題のないプロジェクトでは [PASS] の行が4件以上表示される" test "$PASS_LINES" -ge 4

hint "最後に「テスト結果: 4件成功 / 0件失敗 / 1件スキップ」の形式で1行出します。区切りは半角スラッシュの前後に半角スペースです。"
assert_stdout_matches "テスト結果: [0-9]+件成功 / 0件失敗 / [0-9]+件スキップ" \
    "集計行を「テスト結果: <成功>件成功 / <失敗>件失敗 / <スキップ>件スキップ」の形式で表示する"

hint "shellcheck がある環境では T5 を実行し、無い環境では [SKIP] の行を出します。どちらの場合も失敗にはしません。"
assert_stdout_matches "\[(PASS|SKIP)\].*shellcheck" \
    "shellcheck が使えるかどうかで T5 を実行するかスキップするか切り替える"

#-------------------------------------------------------------------------------
describe "正常系: 引数を省略したとき"
#-------------------------------------------------------------------------------
# 作業ディレクトリの直下にもプロジェクト一式を置き、引数なしで実行する。
make_project "$WORKDIR"
run_target

hint "引数が無いときはカレントディレクトリを検査します。PROJECT_DIR=\"\${1:-.}\" と書きます。"
assert_status 0 "引数を省略するとカレントディレクトリを検査する"

#-------------------------------------------------------------------------------
describe "異常系: index.html に <title> が無いとき"
#-------------------------------------------------------------------------------
make_project "${WORKDIR}/proj"
sed -i '/<title>/d' "${WORKDIR}/proj/app/index.html"
run_target proj

hint "失敗が1件でもあれば exit 1 です。ここで0を返すと、壊れたものがそのまま配布されてしまいます。"
assert_status 1 "失敗が1件以上あるときは終了ステータス1で終わる"

hint "失敗した項目は [FAIL] で始まる行にします。T3 の説明文は README のとおりに書いてください。"
assert_stdout_contains "[FAIL] T3: app/index.html に <title> タグがある" \
    "<title> が無いときは T3 を [FAIL] として表示する"

#-------------------------------------------------------------------------------
describe "異常系: 構文エラーのあるスクリプトがあるとき"
#-------------------------------------------------------------------------------
make_project "${WORKDIR}/proj"
cat > "${WORKDIR}/proj/scripts/broken.sh" <<'EOF'
#!/bin/bash
if [ 1 -eq 1 ]; then
    echo "fi を閉じ忘れている"
EOF
run_target proj

assert_status 1 "構文エラーのあるスクリプトがあるときは終了ステータス1で終わる"

hint "scripts配下の .sh を1つずつ bash -n で調べます。1つでも失敗したら [FAIL] にしてください。"
assert_stdout_contains "[FAIL] T2: scripts配下のシェルスクリプトに構文エラーが無い" \
    "構文エラーがあるときは T2 を [FAIL] として表示する"

#-------------------------------------------------------------------------------
describe "異常系: 必須ファイルが欠けているとき"
#-------------------------------------------------------------------------------
make_project "${WORKDIR}/proj"
rm -f "${WORKDIR}/proj/scripts/deploy.sh"
run_target proj

assert_status 1 "必須ファイルが欠けているときは終了ステータス1で終わる"

hint "必須ファイルは app/index.html と scripts/deploy.sh の2つです。どちらか一方でも無ければ [FAIL] です。"
assert_stdout_contains "[FAIL] T1: 必須ファイルが存在する" \
    "必須ファイルが無いときは T1 を [FAIL] として表示する"

#-------------------------------------------------------------------------------
describe "異常系: シバンが #!/bin/bash でないとき"
#-------------------------------------------------------------------------------
make_project "${WORKDIR}/proj"
sed -i '1s|.*|#!/bin/sh|' "${WORKDIR}/proj/scripts/build.sh"
run_target proj

assert_status 1 "シバンが違うスクリプトがあるときは終了ステータス1で終わる"

hint "1行目を head -n 1 で取り出し、文字列 #!/bin/bash と完全一致するか比べます。"
assert_stdout_contains "[FAIL] T4: scripts配下のシェルスクリプトの1行目が #!/bin/bash である" \
    "シバンが違うときは T4 を [FAIL] として表示する"

#-------------------------------------------------------------------------------
describe "異常系: 存在しないディレクトリを指定したとき"
#-------------------------------------------------------------------------------
run_target no_such_dir

hint "検査そのものができない状態なので、テストの失敗として数えず、すぐ exit 1 で終わります。"
assert_status 1 "存在しないディレクトリを指定すると終了ステータス1で終わる"

hint "エラーメッセージは echo \"...\" >&2 のように標準エラー出力へ出します。"
assert_stderr_contains "エラー: ディレクトリが見つかりません: no_such_dir" \
    "存在しないディレクトリ名を添えたエラーを標準エラー出力に表示する"

finish
