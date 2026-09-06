#!/bin/bash
#===============================================================================
# ex20 の採点テスト
#   check.sh から呼び出される。単体で直接実行するものではない。
#
#   この演習の対象はシェルスクリプトではなくYAMLファイル
#   (GitHub Actions のワークフロー定義)なので、bash の構文チェック
#   (assert_no_syntax_error)は行わない。
#   代わりに、必要なキーと値が書かれているかを正規表現で1行ずつ確認し、
#   最後にYAMLとして読み込めるかを検査する。
#
#   採点でGitHubへ接続したり、実際にワークフローを動かしたりすることは
#   一切ない。ファイルの中身だけを見る。
#===============================================================================

# shellcheck source=../../lib/harness.sh
source "${EX_LIB}/harness.sh"

require_target

# タブ文字。YAMLではインデントにタブを使えないため、混入していないか調べる。
TAB="$(printf '\t')"

#-------------------------------------------------------------------------------
describe "全体: ファイルの体裁とYAMLの書式"
#-------------------------------------------------------------------------------
hint "TODO の行はすべて消して、実際の設定を書いてください。"
assert_file_not_contains "$TARGET" "TODO" "雛形の TODO 行が残っていない"

hint "インデントにタブが混ざっています。半角スペース2つに置き換えてください。エディタの設定で「タブをスペースに変換」を有効にすると防げます。"
assert_file_not_contains "$TARGET" "$TAB" "インデントにタブ文字を使っていない"

#-------------------------------------------------------------------------------
describe "name と on: ワークフローの名前と、いつ動かすか"
#-------------------------------------------------------------------------------
hint "一番外側のキーなので、行頭にインデントなしで name: deploy と書きます。"
assert_file_contains "$TARGET" '^name:[[:space:]]*deploy[[:space:]]*$' \
    "name: deploy でワークフローの名前を付ける"

hint "on: の2スペース下に push: と書きます。コロンの後ろには何も書きません。"
assert_file_contains "$TARGET" '^[[:space:]]*push:[[:space:]]*$' \
    "push トリガーを定義する"

hint "プルリクエストのトリガーです。キーは pull_request で、アンダースコア区切りです。"
assert_file_contains "$TARGET" '^[[:space:]]*pull_request:[[:space:]]*$' \
    "pull_request トリガーを定義する"

hint "手動実行のトリガーです。値は不要なので workflow_dispatch: とキーだけの行にします。"
assert_file_contains "$TARGET" '^[[:space:]]*workflow_dispatch:[[:space:]]*$' \
    "workflow_dispatch トリガーを定義して手動実行できるようにする"

hint "対象ブランチの指定です。branches: [ main ] と、角括弧を使ったリストで書きます。"
assert_file_contains "$TARGET" '^[[:space:]]*branches:[[:space:]]*\[[[:space:]]*main[[:space:]]*\][[:space:]]*$' \
    "branches: [ main ] で main ブランチを対象にする"

#-------------------------------------------------------------------------------
describe "jobs: 2つのジョブの構造"
#-------------------------------------------------------------------------------
hint "ジョブを並べる前に jobs: という行が必要です。行頭にインデントなしで書きます。"
assert_file_contains "$TARGET" '^jobs:[[:space:]]*$' "jobs: でジョブの並びを始める"

# ジョブが2つあること(test と deploy)を、runs-on の行数で確認する。
RUNS_ON_COUNT="$(grep -cE '^[[:space:]]*runs-on:[[:space:]]*ubuntu-latest[[:space:]]*$' "$TARGET" || true)"

hint "test ジョブと deploy ジョブの両方に runs-on: ubuntu-latest が必要です。ジョブごとに別々のランナー(仮想マシン)を借りるため、1つにまとめることはできません。"
assert_eq "2" "$RUNS_ON_COUNT" "test と deploy の2つのジョブに runs-on: ubuntu-latest を書く"

# checkout も同じ理由で2回必要になる。
CHECKOUT_COUNT="$(grep -cE '^[[:space:]]*-[[:space:]]*uses:[[:space:]]*actions/checkout@v4[[:space:]]*$' "$TARGET" || true)"

hint "ジョブごとにランナーはまっさらな状態から始まるため、deploy ジョブでも改めて - uses: actions/checkout@v4 が必要です。@v4 のバージョン指定も忘れずに書いてください。"
assert_eq "2" "$CHECKOUT_COUNT" "両方のジョブの先頭で actions/checkout@v4 を呼び出す"

#-------------------------------------------------------------------------------
describe "deploy ジョブ: いつ配布してよいかの条件"
#-------------------------------------------------------------------------------
hint "先に成功していなければならないジョブを指定します。needs: test と書きます。"
assert_file_contains "$TARGET" '^[[:space:]]*needs:[[:space:]]*test[[:space:]]*$' \
    "needs: test でテスト成功後だけ配布する"

hint "main ブランチのときだけ動かす条件です。if: github.ref == 'refs/heads/main' と書きます。ブランチ名だけの main では一致しません。"
assert_file_contains "$TARGET" "^[[:space:]]*if:.*refs/heads/main" \
    "if で refs/heads/main のときだけ deploy ジョブを動かす"

#-------------------------------------------------------------------------------
describe "Secrets と秘密鍵の扱い"
#-------------------------------------------------------------------------------
hint "秘密鍵の中身は書かず、\${{ secrets.SSH_PRIVATE_KEY }} という書き方で参照します。"
assert_file_contains "$TARGET" '\$\{\{[[:space:]]*secrets\.SSH_PRIVATE_KEY[[:space:]]*\}\}' \
    "秘密鍵を secrets.SSH_PRIVATE_KEY から受け取る"

# 配布先のユーザー名とホスト名の2種類が Secrets 経由になっているか。
# 同じ行に並べて書かれることがあるため、行数ではなく出現した種類の数を数える。
DEPLOY_SECRETS="$(grep -oE '\$\{\{[[:space:]]*secrets\.DEPLOY_(USER|HOST)[[:space:]]*\}\}' "$TARGET" \
    | sed -E 's/[^A-Z_]//g' | sort -u | wc -l)"

hint "配布先も秘密情報として扱います。\${{ secrets.DEPLOY_USER }} と \${{ secrets.DEPLOY_HOST }} の2種類を参照してください。"
assert_eq "2" "$DEPLOY_SECRETS" "配布先を secrets.DEPLOY_USER と secrets.DEPLOY_HOST から受け取る"

hint "書き出した鍵ファイルの権限を chmod 600 で「持ち主だけが読める」状態にします。これを忘れると SSH が接続を拒否します。"
assert_file_contains "$TARGET" 'chmod[[:space:]]+600' \
    "chmod 600 で秘密鍵ファイルの権限を絞る"

#-------------------------------------------------------------------------------
describe "書式検査: YAMLとして読み込めるか"
#-------------------------------------------------------------------------------
# PyYAML(pythonのYAML読み込みライブラリ)がある環境でだけ検査する。
if python3 -c 'import yaml' 2> /dev/null; then
    hint "インデントのずれ、コロンの後ろのスペース忘れ、全角文字の混入が原因のことが多いです。"
    assert_cmd "YAMLとして構文エラーがない" \
        python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' "$TARGET"
else
    skip "PyYAMLが無いためYAML構文チェックを省略します"
fi

finish
