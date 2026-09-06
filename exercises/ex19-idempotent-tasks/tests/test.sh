#!/bin/bash
#===============================================================================
# ex19 の採点テスト
#   check.sh から呼び出される。単体で直接実行するものではない。
#
#   この演習の対象はシェルスクリプトではなくYAMLファイル(Ansibleのタスク定義)
#   なので、bash の構文チェック(assert_no_syntax_error)は行わない。
#   代わりに「shell / command が残っていないか」「専用モジュールに
#   書き換えられているか」を正規表現で確認し、最後にYAMLとして
#   読み込めるかを検査する。
#
#   採点でサーバーに接続したり ansible-playbook を実行したりすることは一切ない。
#   ファイルの中身だけを見る。
#===============================================================================

# shellcheck source=../../lib/harness.sh
source "${EX_LIB}/harness.sh"

require_target

# タブ文字。YAMLではインデントにタブを使えないため、混入していないか調べる。
TAB="$(printf '\t')"

#-------------------------------------------------------------------------------
describe "全体: ファイルの体裁"
#-------------------------------------------------------------------------------
hint "TODO の行はすべて消して、書き換えたタスクだけを残してください。"
assert_file_not_contains "$TARGET" "TODO" "雛形の TODO 行が残っていない"

hint "インデントにタブが混ざっています。半角スペース2つに置き換えてください。エディタの設定で「タブをスペースに変換」を有効にすると防げます。"
assert_file_not_contains "$TARGET" "$TAB" "インデントにタブ文字を使っていない"

# タスクの区切りは行頭の「- name:」。書き換えの過程でタスクを消したり
# 増やしたりしていないかを、この行数で確認する。
TASK_COUNT="$(grep -cE '^-[[:space:]]+name:' "$TARGET" || true)"

hint "タスクは5つのままです。行頭の「- name:」の数を数えてください。書き換えのときにタスクを消したり、1つのタスクを2つに分けたりしていませんか。"
assert_eq "5" "$TASK_COUNT" "タスクが5つある"

#-------------------------------------------------------------------------------
describe "べき等でない書き方が残っていないこと"
#-------------------------------------------------------------------------------
hint "shell モジュールの行が残っています。5つのタスクすべてを専用モジュールに書き換えてください。"
assert_file_not_contains "$TARGET" '^[[:space:]]{0,3}(ansible\.builtin\.)?shell:' \
    "shell モジュールを1つも使っていない"

hint "command モジュールの行が残っています。systemctl start は service モジュールで置き換えられます。"
assert_file_not_contains "$TARGET" '^[[:space:]]{0,3}(ansible\.builtin\.)?command:' \
    "command モジュールを1つも使っていない"

#-------------------------------------------------------------------------------
describe "タスク1: ユーザーの作成"
#-------------------------------------------------------------------------------
hint "useradd の代わりは ansible.builtin.user モジュールです。行末はコロンで終わり、引数は次の行から2スペース下げて書きます。"
assert_file_contains "$TARGET" '^[[:space:]]*ansible\.builtin\.user:[[:space:]]*$' \
    "ansible.builtin.user モジュールでユーザーを作成する"

#-------------------------------------------------------------------------------
describe "タスク2: ディレクトリの作成"
#-------------------------------------------------------------------------------
hint "mkdir の代わりは ansible.builtin.file モジュールです。"
assert_file_contains "$TARGET" '^[[:space:]]*ansible\.builtin\.file:[[:space:]]*$' \
    "ansible.builtin.file モジュールでディレクトリを作成する"

hint "file モジュールで「ディレクトリとして存在する状態にする」指定です。state: directory と書きます。"
assert_file_contains "$TARGET" '^[[:space:]]*state:[[:space:]]*directory[[:space:]]*$' \
    "file に state: directory を指定する"

#-------------------------------------------------------------------------------
describe "タスク3: 設定ファイルへの1行の追加"
#-------------------------------------------------------------------------------
hint "echo と >> の代わりは ansible.builtin.lineinfile モジュールです。"
assert_file_contains "$TARGET" '^[[:space:]]*ansible\.builtin\.lineinfile:[[:space:]]*$' \
    "ansible.builtin.lineinfile モジュールで設定行を書き込む"

hint "regexp: \"^#?PermitRootLogin\" と書きます。これが「同じ設定の行を探して置き換える」ための目印になり、2回実行しても行が2つに増えなくなります。"
assert_file_contains "$TARGET" \
    "^[[:space:]]*regexp:[[:space:]]*[\"']?\^#\?PermitRootLogin[\"']?[[:space:]]*\$" \
    "lineinfile に regexp: \"^#?PermitRootLogin\" を指定する"

#-------------------------------------------------------------------------------
describe "タスク4: サービスの起動"
#-------------------------------------------------------------------------------
hint "systemctl start の代わりは ansible.builtin.service モジュールです。"
assert_file_contains "$TARGET" '^[[:space:]]*ansible\.builtin\.service:[[:space:]]*$' \
    "ansible.builtin.service モジュールでサービスを起動する"

hint "「今動いている状態にする」という指定です。state: started と書きます。"
assert_file_contains "$TARGET" '^[[:space:]]*state:[[:space:]]*started[[:space:]]*$' \
    "service に state: started を指定する"

hint "OS再起動後も自動で立ち上がるようにする指定です。enabled: true と書きます。"
assert_file_contains "$TARGET" '^[[:space:]]*enabled:[[:space:]]*true[[:space:]]*$' \
    "service に enabled: true を指定する"

#-------------------------------------------------------------------------------
describe "タスク5: パッケージのインストール"
#-------------------------------------------------------------------------------
hint "apt-get install の代わりは ansible.builtin.apt モジュールです。"
assert_file_contains "$TARGET" '^[[:space:]]*ansible\.builtin\.apt:[[:space:]]*$' \
    "ansible.builtin.apt モジュールでパッケージを導入する"

hint "「入っている状態にする」「存在する状態にする」という指定です。state: present と書きます。"
assert_file_contains "$TARGET" '^[[:space:]]*state:[[:space:]]*present[[:space:]]*$' \
    "state: present であるべき状態を宣言する"

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
