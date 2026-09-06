#!/bin/bash
#===============================================================================
# _recorder.sh — ダミーコマンド(スタブ)の本体
#
# 概要:
#   このファイルは、採点時に useradd / ping / curl などの名前でコピーされ、
#   本物のコマンドの代わりに実行される「偽物」です。
#
#   偽物にする理由は2つあります。
#     1. 安全性: 採点のたびに本物の useradd が動いて、あなたのPCに
#        ユーザーが増えてしまっては困る。
#     2. 手軽さ: ping や curl の相手サーバーを用意しなくても、
#        「サーバーが落ちているとき」の挙動まで再現して練習できる。
#
#   呼び出された内容は $STUB_LOG に1行ずつ記録され、
#   テスト側から assert_stub_called などで検証されます。
#
# 動作を変えるための環境変数(テスト側で設定する):
#   STUB_EXISTING_USERS   既に存在することにするユーザー名(空白区切り)
#   STUB_EXISTING_GROUPS  既に存在することにするグループ名(空白区切り)
#   STUB_FAIL_CMDS        強制的に失敗(終了ステータス1)させるコマンド名
#   STUB_DOWN_HOSTS       停止中ということにするホスト名(ping/curlが失敗)
#   STUB_HTTP_CODE        curl が返すHTTPステータスコード(既定: 200)
#   STUB_HTTP_CODES       ホストごとの指定 例: "web01=200 web02=500"
#   STUB_ACTIVE_UNITS     起動中ということにするsystemdユニット名
#===============================================================================

set -u

_cmd="$(basename "$0")"

#-------------------------------------------------------------------------------
# 呼び出し内容をログに記録する
#   引数に改行が含まれると1行1呼び出しの形が崩れるため、改行は \n に置換する。
#-------------------------------------------------------------------------------
if [[ -n "${STUB_LOG:-}" ]]; then
    {
        printf '%s' "$_cmd"
        for _a in "$@"; do
            printf ' %s' "${_a//$'\n'/\\n}"
        done
        printf '\n'
    } >> "$STUB_LOG"
fi

#-------------------------------------------------------------------------------
# 強制失敗の指定があるか(異常系のテストで使う)
#-------------------------------------------------------------------------------
for _f in ${STUB_FAIL_CMDS:-}; do
    if [[ "$_f" == "$_cmd" ]]; then
        echo "${_cmd}: 疑似的な失敗(STUB_FAIL_CMDS による)" >&2
        exit 1
    fi
done

#-------------------------------------------------------------------------------
# 補助関数: 空白区切りリストに値が含まれるか
#-------------------------------------------------------------------------------
_in_list() {
    local needle="$1" list="${2:-}" item
    # $list は「空白区切りの一覧」なので、あえてクォートせず単語分割させる
    for item in ${list}; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

#-------------------------------------------------------------------------------
# 補助関数: 引数からホスト名/URLらしきものを取り出す
#-------------------------------------------------------------------------------
#   ping web01 / ping -c 1 -W 2 web01 のように、ホスト名は最後に置かれる
#   ことが多いため「オプション以外の最後の引数」を採用する。
_extract_host() {
    local a last=""
    for a in "$@"; do
        case "$a" in
            -*) continue ;;
            http://*|https://*)
                a="${a#*://}"      # スキームを除去
                a="${a%%/*}"       # パスを除去
                a="${a%%:*}"       # ポートを除去
                echo "$a"
                return 0
                ;;
            *) last="$a" ;;
        esac
    done
    echo "$last"
}

#-------------------------------------------------------------------------------
# コマンドごとの振る舞い
#-------------------------------------------------------------------------------
case "$_cmd" in

    #---------------------------------------------------------------------------
    # getent: ユーザー/グループの存在確認
    #   本物と同じく、見つかれば0、見つからなければ2を返す。
    #---------------------------------------------------------------------------
    getent)
        _db="${1:-}"
        _key="${2:-}"
        case "$_db" in
            passwd)
                if _in_list "$_key" "${STUB_EXISTING_USERS:-}"; then
                    echo "${_key}:x:1500:1500::/home/${_key}:/bin/bash"
                    exit 0
                fi
                exit 2
                ;;
            group)
                if _in_list "$_key" "${STUB_EXISTING_GROUPS:-}"; then
                    echo "${_key}:x:1500:"
                    exit 0
                fi
                exit 2
                ;;
            *)
                exit 2
                ;;
        esac
        ;;

    #---------------------------------------------------------------------------
    # ユーザー・グループ管理系: 記録するだけで成功を返す
    #---------------------------------------------------------------------------
    useradd|usermod|userdel|groupadd|groupdel|chpasswd|chage|passwd)
        # chpasswd は標準入力を読むため、詰まらないように読み捨てる
        if [[ "$_cmd" == "chpasswd" || "$_cmd" == "passwd" ]]; then
            if [[ ! -t 0 ]]; then
                cat > /dev/null
            fi
        fi
        exit 0
        ;;

    #---------------------------------------------------------------------------
    # ping: 疎通確認
    #   STUB_DOWN_HOSTS に含まれるホストは「応答なし」として失敗する。
    #---------------------------------------------------------------------------
    ping)
        _host="$(_extract_host "$@")"
        if _in_list "$_host" "${STUB_DOWN_HOSTS:-}"; then
            echo "PING ${_host} (192.0.2.1) 56(84) bytes of data."
            echo ""
            echo "--- ${_host} ping statistics ---"
            echo "1 packets transmitted, 0 received, 100% packet loss, time 0ms"
            exit 1
        fi
        echo "PING ${_host} (192.0.2.1) 56(84) bytes of data."
        echo "64 bytes from ${_host} (192.0.2.1): icmp_seq=1 ttl=64 time=0.123 ms"
        echo ""
        echo "--- ${_host} ping statistics ---"
        echo "1 packets transmitted, 1 received, 0% packet loss, time 0ms"
        exit 0
        ;;

    #---------------------------------------------------------------------------
    # curl: HTTP通信
    #   -o <file>          応答本文の出力先
    #   -w <format>        %{http_code} を実際のコードに置き換えて出力
    #   -I / --head        応答ヘッダーのみ表示
    #   -d / --data / --data-binary  POST送信(Webhook通知の練習で使用)
    #---------------------------------------------------------------------------
    curl)
        _out=""
        _fmt=""
        _head="no"
        _url=""
        _failflag="no"
        _prev=""
        for _a in "$@"; do
            case "$_prev" in
                -o|--output) _out="$_a"; _prev=""; continue ;;
                -w|--write-out) _fmt="$_a"; _prev=""; continue ;;
                -d|--data|--data-raw|--data-binary|-H|--header|-X|--request|-m|--max-time|--connect-timeout|-u|--user)
                    _prev=""; continue ;;
            esac
            case "$_a" in
                -I|--head) _head="yes" ;;
                -f|--fail) _failflag="yes" ;;
                -o|--output|-w|--write-out|-d|--data|--data-raw|--data-binary|-H|--header|-X|--request|-m|--max-time|--connect-timeout|-u|--user)
                    _prev="$_a" ;;
                http://*|https://*) _url="$_a" ;;
                *) : ;;
            esac
        done

        _host="${_url#*://}"; _host="${_host%%/*}"; _host="${_host%%:*}"

        # ホストごとのHTTPステータスコードを決める
        _code="${STUB_HTTP_CODE:-200}"
        for _pair in ${STUB_HTTP_CODES:-}; do
            if [[ "${_pair%%=*}" == "$_host" ]]; then
                _code="${_pair#*=}"
            fi
        done
        if _in_list "$_host" "${STUB_DOWN_HOSTS:-}"; then
            _code="000"
        fi

        # 応答本文を組み立てる
        if [[ "$_head" == "yes" ]]; then
            _body="HTTP/1.1 ${_code} OK"$'\n'"Server: nginx"$'\n'"Content-Type: text/html"
        else
            _body="ok"
        fi

        if [[ "$_code" == "000" ]]; then
            # 接続失敗。本物の curl と同じく終了ステータス7を返す。
            [[ -n "$_fmt" ]] && printf '%s' "${_fmt//%\{http_code\}/000}"
            echo "curl: (7) Failed to connect to ${_host}: Connection refused" >&2
            exit 7
        fi

        if [[ -n "$_out" ]]; then
            printf '%s\n' "$_body" > "$_out"
        else
            printf '%s\n' "$_body"
        fi

        if [[ -n "$_fmt" ]]; then
            _rendered="${_fmt//%\{http_code\}/$_code}"
            _rendered="${_rendered//%\{time_total\}/0.012345}"
            _rendered="${_rendered//\\n/$'\n'}"
            printf '%s' "$_rendered"
        fi

        if [[ "$_failflag" == "yes" && "$_code" -ge 400 ]]; then
            echo "curl: (22) The requested URL returned error: ${_code}" >&2
            exit 22
        fi
        exit 0
        ;;

    #---------------------------------------------------------------------------
    # systemctl: サービス管理
    #---------------------------------------------------------------------------
    systemctl)
        case "${1:-}" in
            is-active)
                if _in_list "${2:-}" "${STUB_ACTIVE_UNITS:-}"; then
                    echo "active"
                    exit 0
                fi
                echo "inactive"
                exit 3
                ;;
            status)
                echo "● ${2:-unit} - dummy unit"
                echo "     Active: active (running)"
                exit 0
                ;;
            *)
                exit 0
                ;;
        esac
        ;;

    #---------------------------------------------------------------------------
    # その他(logger / mail / ssh / rsync など): 記録するだけで成功を返す
    #---------------------------------------------------------------------------
    *)
        exit 0
        ;;
esac
