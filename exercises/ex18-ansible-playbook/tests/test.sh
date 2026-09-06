#!/bin/bash
#===============================================================================
# ex18 の採点テスト
#   check.sh から呼び出される。単体で直接実行するものではない。
#
#   この演習の対象はシェルスクリプトではなくYAMLファイル(Ansible Playbook)
#   なので、bash の構文チェック(assert_no_syntax_error)は行わない。
#   代わりに、必要なキーと値が書かれているかを正規表現で1行ずつ確認し、
#   最後にYAMLとして読み込めるかを検査する。
#
#   採点でサーバーに接続したり ansible-playbook を実行したりすることは一切ない。
#   ファイルの中身だけを見る。
#===============================================================================

# shellcheck source=../../lib/harness.sh
source "${EX_LIB}/harness.sh"

require_target

# ハンドラの名前。notify に書く文字列と一致していなければならない。
HANDLER_NAME="nginx を再起動する"

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
describe "play の設定: どのサーバーに、どの権限で、どの変数で実行するか"
#-------------------------------------------------------------------------------
hint "キーは hosts 、値は webservers です。コロンの後ろには半角スペースを1つ入れます。"
assert_file_contains "$TARGET" '^[[:space:]]*hosts:[[:space:]]*webservers[[:space:]]*$' \
    "hosts: webservers で対象のホストグループを指定する"

hint "管理者権限で実行する指定です。キーは become 、値は true です。"
assert_file_contains "$TARGET" '^[[:space:]]*become:[[:space:]]*true[[:space:]]*$' \
    "become: true で管理者権限(sudo)で実行する"

hint "変数は vars: という行を書き、その下にぶら下げます。"
assert_file_contains "$TARGET" '^[[:space:]]*vars:[[:space:]]*$' "vars: で変数の定義を始める"

hint "vars: の2スペース下に nginx_port: 80 と書きます。"
assert_file_contains "$TARGET" '^[[:space:]]*nginx_port:[[:space:]]*80[[:space:]]*$' \
    "nginx_port: 80 を変数として定義する"

#-------------------------------------------------------------------------------
describe "tasks: nginx のインストール"
#-------------------------------------------------------------------------------
hint "タスクを並べる前に tasks: という行が必要です。値は書かず、下にタスクをぶら下げます。"
assert_file_contains "$TARGET" '^[[:space:]]*tasks:[[:space:]]*$' "tasks: でタスクの並びを始める"

hint "モジュール名は ansible.builtin.apt: と正式名称(FQCN)で書きます。行末はコロンで終わり、引数は次の行から2スペース下げて書きます。"
assert_file_contains "$TARGET" '^[[:space:]]*ansible\.builtin\.apt:[[:space:]]*$' \
    "ansible.builtin.apt モジュールで nginx をインストールする"

hint "「入っている状態にする」という指定です。state: present と書きます。"
assert_file_contains "$TARGET" '^[[:space:]]*state:[[:space:]]*present[[:space:]]*$' \
    "apt に state: present を指定する"

#-------------------------------------------------------------------------------
describe "tasks: 設定ファイルの配置"
#-------------------------------------------------------------------------------
hint "モジュール名は ansible.builtin.template: です。"
assert_file_contains "$TARGET" '^[[:space:]]*ansible\.builtin\.template:[[:space:]]*$' \
    "ansible.builtin.template モジュールで設定ファイルを配置する"

hint "配置先は絶対パスで書きます。dest: /etc/nginx/nginx.conf です。"
assert_file_contains "$TARGET" '^[[:space:]]*dest:[[:space:]]*/etc/nginx/nginx\.conf[[:space:]]*$' \
    "template に dest: /etc/nginx/nginx.conf を指定する"

hint "mode の値はクォートで囲みます。mode: \"0644\" と書いてください。クォートの無い 644 はYAMLが10進数として読み込み、意図しない権限になります。"
assert_file_contains "$TARGET" "^[[:space:]]*mode:[[:space:]]*[\"']0644[\"'][[:space:]]*\$" \
    "template の mode を \"0644\" とクォートして指定する"

hint "設定が変わったときだけハンドラを呼ぶ指定です。モジュール名と同じ深さに notify: ${HANDLER_NAME} と書きます。"
assert_file_contains "$TARGET" "^[[:space:]]*notify:[[:space:]]*${HANDLER_NAME}[[:space:]]*\$" \
    "template のタスクに notify: ${HANDLER_NAME} を書く"

#-------------------------------------------------------------------------------
describe "tasks: サービスの起動と自動起動"
#-------------------------------------------------------------------------------
hint "モジュール名は ansible.builtin.service: です。"
assert_file_contains "$TARGET" '^[[:space:]]*ansible\.builtin\.service:[[:space:]]*$' \
    "ansible.builtin.service モジュールでサービスを操作する"

hint "「今動いている状態にする」という指定です。state: started と書きます。"
assert_file_contains "$TARGET" '^[[:space:]]*state:[[:space:]]*started[[:space:]]*$' \
    "service に state: started を指定する"

hint "OS再起動後も自動で立ち上がるようにする指定です。enabled: true と書きます。"
assert_file_contains "$TARGET" '^[[:space:]]*enabled:[[:space:]]*true[[:space:]]*$' \
    "service に enabled: true を指定する"

#-------------------------------------------------------------------------------
describe "handlers: 変更があったときだけ動く後処理"
#-------------------------------------------------------------------------------
hint "handlers: は tasks: と同じ深さ(play の直下)に書きます。"
assert_file_contains "$TARGET" '^[[:space:]]*handlers:[[:space:]]*$' \
    "handlers: でハンドラの定義を始める"

hint "ハンドラの中身は state: restarted です。started ではなく restarted を指定します。"
assert_file_contains "$TARGET" '^[[:space:]]*state:[[:space:]]*restarted[[:space:]]*$' \
    "ハンドラに state: restarted を指定する"

# notify に書いた文字列と、handlers の name は一字一句同じでなければならない。
# 同じ文字列が「notify: ...」と「- name: ...」の2行に現れることを数えて確認する。
NAME_LINE_COUNT="$(grep -cE "^[[:space:]]*(notify:|- name:)[[:space:]]*${HANDLER_NAME}[[:space:]]*\$" "$TARGET" || true)"

hint "notify の値と handlers の name が一字一句同じでないと、ハンドラは呼ばれません。全角スペースや表記ゆれに注意してください。"
assert_eq "2" "$NAME_LINE_COUNT" \
    "notify の値と handlers の name が同じ文字列「${HANDLER_NAME}」になっている"

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
