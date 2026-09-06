#!/bin/bash
#===============================================================================
# ex14 の採点テスト
#   check.sh から呼び出される。単体で直接実行するものではない。
#
#   この演習の対象はシェルスクリプトではなく設定ファイル(systemdユニット)
#   なので、bash の構文チェック(assert_no_syntax_error)は行わない。
#   代わりに、必要なセクションとディレクティブが書かれているかを
#   正規表現で1行ずつ確認する。
#
#   採点でサービスを起動することは一切ない。ファイルの中身だけを見る。
#===============================================================================

# shellcheck source=../../lib/harness.sh
source "${EX_LIB}/harness.sh"

require_target

#-------------------------------------------------------------------------------
describe "全体: ファイルの体裁"
#-------------------------------------------------------------------------------
hint "「TODO 1:」のように番号の付いた指示コメントの行は、設定を書いたらすべて消してください。"
assert_file_not_contains "$TARGET" '#[[:space:]]*TODO[[:space:]]*[0-9]' \
    "雛形の「TODO <番号>:」の指示コメント行が残っていない"

#-------------------------------------------------------------------------------
describe "[Unit] セクション: 説明と起動順序"
#-------------------------------------------------------------------------------
hint "セクション見出しは行頭から [Unit] と書きます。先頭に空白を入れないでください。"
assert_file_contains "$TARGET" '^\[Unit\][[:space:]]*$' "[Unit] セクションを書く"

hint "書式は Description=ログ監視・異常検知アラート通知サービス です。= の前後に空白を入れません。"
assert_file_contains "$TARGET" '^Description=ログ監視・異常検知アラート通知サービス[[:space:]]*$' \
    "Description にサービスの説明を書く"

hint "ネットワークが使えるようになってから起動したいので After を使います。"
assert_file_contains "$TARGET" '^After=network-online\.target[[:space:]]*$' \
    "After=network-online.target で起動順序を指定する"

hint "After は順序を決めるだけです。相手も一緒に起動させるには Wants が要ります。"
assert_file_contains "$TARGET" '^Wants=network-online\.target[[:space:]]*$' \
    "Wants=network-online.target で依存を指定する"

#-------------------------------------------------------------------------------
describe "[Service] セクション: 何をどう動かすか"
#-------------------------------------------------------------------------------
hint "セクション見出しは行頭から [Service] と書きます。"
assert_file_contains "$TARGET" '^\[Service\][[:space:]]*$' "[Service] セクションを書く"

hint "常駐して動き続けるスクリプトなので Type=simple です。"
assert_file_contains "$TARGET" '^Type=simple[[:space:]]*$' \
    "Type=simple で起動モードを指定する"

hint "ExecStart は / から始まる絶対パスで書きます。相対パスやチルダは使えません。"
assert_file_contains "$TARGET" '^ExecStart=/opt/scripts/log-watch-alert\.sh[[:space:]]*$' \
    "ExecStart に実行するスクリプトを絶対パスで指定する"

hint "パスの直前の - が「ファイルが無くても起動する」という意味です。- を書き忘れていませんか。"
assert_file_contains "$TARGET" '^EnvironmentFile=-/etc/default/log-watch-alert[[:space:]]*$' \
    "EnvironmentFile=- で設定ファイルを読み込む(無くても起動する)"

hint "監視サービスは黙って止まるのが最も危険なので、常に再起動する always を使います。"
assert_file_contains "$TARGET" '^Restart=always[[:space:]]*$' \
    "Restart=always で自動再起動を有効にする"

hint "キーは RestartSec 、値は 10 です(単位を書かなければ秒)。"
assert_file_contains "$TARGET" '^RestartSec=10[[:space:]]*$' \
    "RestartSec=10 で再起動までの待ち時間を指定する"

hint "ログを読むために root で動かします。キーは User です。"
assert_file_contains "$TARGET" '^User=root[[:space:]]*$' "User=root で実行ユーザーを指定する"

hint "標準出力の行き先です。キーは StandardOutput 、値は journal です。"
assert_file_contains "$TARGET" '^StandardOutput=journal[[:space:]]*$' \
    "StandardOutput=journal で標準出力を journald に送る"

hint "標準エラー出力も忘れずに指定します。キーは StandardError です。"
assert_file_contains "$TARGET" '^StandardError=journal[[:space:]]*$' \
    "StandardError=journal で標準エラー出力を journald に送る"

#-------------------------------------------------------------------------------
describe "[Install] セクション: 自動起動の設定"
#-------------------------------------------------------------------------------
hint "このセクションが無いと systemctl enable しても何も起こりません。"
assert_file_contains "$TARGET" '^\[Install\][[:space:]]*$' "[Install] セクションを書く"

hint "通常のマルチユーザー起動の一員として登録します。値は multi-user.target です。"
assert_file_contains "$TARGET" '^WantedBy=multi-user\.target[[:space:]]*$' \
    "WantedBy=multi-user.target でOS起動時の自動起動対象にする"

#-------------------------------------------------------------------------------
describe "書式検査: systemd-analyze verify"
#-------------------------------------------------------------------------------
# systemd が入っていない環境(WSLの一部やコンテナなど)ではスキップする。
if command -v systemd-analyze > /dev/null 2>&1; then
    # ExecStart が指す /opt/scripts/log-watch-alert.sh は採点環境に存在しないため、
    # そのまま検査すると「実行ファイルが無い」と怒られてしまう。
    # 検査用のコピーを作り、ExecStart の行だけダミーのスクリプトに差し替える。
    DUMMY_EXEC="${WORKDIR}/dummy-exec.sh"
    printf '#!/bin/bash\nsleep 1\n' > "$DUMMY_EXEC"
    chmod +x "$DUMMY_EXEC"

    mkdir -p "${WORKDIR}/verify"
    VERIFY_UNIT="${WORKDIR}/verify/log-watch-alert.service"
    sed "s#^ExecStart=.*#ExecStart=${DUMMY_EXEC}#" "$TARGET" > "$VERIFY_UNIT"

    hint "= の前後の空白、行頭の空白、全角記号の混入、キー名の大文字小文字を確認してください。"
    assert_cmd "systemd-analyze verify でユニットファイルの書式エラーが出ない" \
        systemd-analyze verify "$VERIFY_UNIT"
else
    skip "systemd-analyze が無い環境のため、ユニットファイルの書式検査は省略します"
fi

finish
