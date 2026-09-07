#!/usr/bin/env bash
#
# =====================================================================
# remote_probe.sh
# 改善案件No.6: サーバー台帳の自動収集・差分検知 - 情報収集スクリプト(対象サーバー側)
#
# 役割:
#   「調査対象となるサーバーの上で実行され、構成情報をテキストで吐き出すだけ」
#   のスクリプト。JSONへの組み立てや差分の判定は一切行わない。
#
# なぜ役割を分けるのか:
#   対象サーバーに jq(=JSONを扱うコマンド)が入っていない環境は珍しくない。
#   このスクリプトは「シェルの標準的なコマンドだけ」で完結させ、
#   JSON化は管理サーバー側(collect_inventory.sh)に任せることで、
#   対象サーバーに追加のソフトをインストールせずに済む設計にしている。
#
# 実行のされ方:
#   管理サーバーから、次のようにファイルの中身を送り込んで実行される。
#     ssh -o BatchMode=yes web01 'bash -s' < remote_probe.sh
#   ローカルモードでは、単に次のように実行される。
#     bash remote_probe.sh
#   どちらの場合も「対象サーバーにこのファイルを置く必要がない」のが利点
#   (置いてしまうと、更新のたびに全台へ配布し直す手間が発生するため)。
#
# 出力形式:
#   1行1項目のTSV(タブ区切り)。1列目がキー、2列目以降が値。
#     os_name<TAB>Ubuntu 24.04.4 LTS
#     disk<TAB>/<TAB>264212084<TAB>22
#   同じキーが複数行出てよい(package / user / port などのリスト項目)。
#   JSONではなくTSVにしているのは、
#     (1) jqなしで生成できる
#     (2) 人間が目で読める
#     (3) 管理サーバー側で jq がそのまま配列に変換できる
#   という3点を満たすため。
#
# 環境変数(管理サーバー側から渡される。未設定でも動く):
#   PROBE_WATCH_PACKAGES : 収集対象パッケージ名の空白区切りリスト
#   PROBE_DISK_MOUNTS    : 収集対象マウントポイントの空白区切りリスト
# =====================================================================

set -u
# -u : 未定義変数の参照をエラーにする(タイプミスの早期発見)。
# -e は付けない。1つの項目が取得できなくても、残りの項目の収集は
# 続けたいため(例: systemd が無い環境でもOS情報は取りたい)。

# 収集対象のパッケージ(既定値)。
# 「全パッケージ」を収集すると数千行になり、セキュリティ更新のたびに
# 大量の差分が出てノイズになるため、監視したいものだけに絞る。
WATCH_PACKAGES="${PROBE_WATCH_PACKAGES:-bash openssh-server nginx cron rsync curl}"

# 収集対象のマウントポイント(既定値)。
DISK_MOUNTS="${PROBE_DISK_MOUNTS:-/ /var /home}"

# 出力を1行書き出す関数。引数をタブで連結する。
# printf を使うのは、echo だとバックスラッシュの扱いがシェルによって
# 変わることがあり、出力が壊れる可能性があるため。
emit() {
    local IFS=$'\t'
    printf '%s\n' "$*"
}

# 取得できなかった項目を記録する関数。
# 「取れなかった」ことを黙って握りつぶすと、台帳上は
# 「そのサービスが存在しない」ように見えてしまい、誤った差分の原因になる。
emit_note() {
    emit "collect_note" "$1" "$2"
}

# ---------------------------------------------------------------
# 1. スキーマ版数
#    出力形式を将来変更したとき、古いスナップショットと区別するための番号。
# ---------------------------------------------------------------
emit "schema_version" "1"

# ---------------------------------------------------------------
# 2. OS情報
#    /etc/os-release は systemd 系ディストリビューションの標準ファイルで、
#    Ubuntu / Debian / RHEL / AlmaLinux などで共通に読める。
# ---------------------------------------------------------------
if [ -r /etc/os-release ]; then
    # サブシェル( ( ) )の中で読み込むことで、os-release が定義する
    # 変数(NAME, VERSION など)が、このスクリプト本体の変数を
    # 上書きしてしまう事故を防ぐ。
    (
        # shellcheck disable=SC1091
        # SC1091: 実行環境にしか存在しないファイルなので静的解析では追えない。
        . /etc/os-release
        emit "os_name" "${PRETTY_NAME:-unknown}"
        emit "os_id" "${ID:-unknown}"
        emit "os_version_id" "${VERSION_ID:-unknown}"
    )
else
    emit "os_name" "unknown"
    emit "os_id" "unknown"
    emit "os_version_id" "unknown"
    emit_note "os" "no_etc_os_release"
fi

# ---------------------------------------------------------------
# 3. カーネル・アーキテクチャ・ホスト名
#    uname -r はカーネルの版数。セキュリティ更新の適用状況を示す
#    重要な指標なので、差分検知の対象に含めている。
# ---------------------------------------------------------------
emit "kernel" "$(uname -r)"
emit "arch" "$(uname -m)"

# hostname -f は FQDN(=ドメイン名まで含んだ完全なホスト名)を返す。
# 名前解決が設定されていない環境では失敗するので、その場合は
# 短いホスト名にフォールバックする。
if hostname_fqdn="$(hostname -f 2>/dev/null)" && [ -n "$hostname_fqdn" ]; then
    emit "hostname" "$hostname_fqdn"
else
    emit "hostname" "$(hostname)"
    emit_note "hostname" "fqdn_unresolved"
fi

# ---------------------------------------------------------------
# 4. IPアドレス(IPv4)
#    ip コマンドが最新の標準だが、最小構成のコンテナ等では
#    入っていないことがあるため hostname -I にフォールバックする。
# ---------------------------------------------------------------
if command -v ip >/dev/null 2>&1; then
    # ip -o -4 addr show の出力例:
    #   2: eth0    inet 192.168.1.11/24 brd ... scope global eth0
    # $4 が "192.168.1.11/24" なので、cut で "/" の前だけを取り出す。
    ip -o -4 addr show scope global 2>/dev/null \
        | awk '{print $4}' | cut -d/ -f1 | sort -u \
        | while read -r addr; do
            [ -n "$addr" ] && emit "ip" "$addr"
        done
elif command -v hostname >/dev/null 2>&1 && hostname -I >/dev/null 2>&1; then
    # hostname -I は「このホストが持つIPアドレスを空白区切りで並べる」オプション。
    for addr in $(hostname -I); do
        case "$addr" in
            *:*) continue ;;  # IPv6は今回の収集対象外なので読み飛ばす
        esac
        emit "ip" "$addr"
    done
    emit_note "ip" "ip_command_missing_used_hostname"
else
    emit_note "ip" "unavailable"
fi

# ---------------------------------------------------------------
# 5. ディスク使用状況
#    df -P は「POSIX準拠の出力形式」を指定するオプション。
#    これを付けないと、デバイス名が長いときに行が折り返されて
#    列がずれ、awk での切り出しが壊れることがある。
# ---------------------------------------------------------------
for mount_point in $DISK_MOUNTS; do
    if [ ! -d "$mount_point" ]; then
        continue
    fi
    # 出力例(2行目):
    #   /dev/vda 264212084 8237072 30611452 22% /
    df_line="$(df -P "$mount_point" 2>/dev/null | awk 'NR==2 {print $2, $5}')"
    if [ -z "$df_line" ]; then
        emit_note "disk" "df_failed:${mount_point}"
        continue
    fi
    size_kb="${df_line%% *}"
    used_pct="${df_line##* }"
    used_pct="${used_pct%\%}"   # 末尾の "%" を取り除いて数値だけにする
    emit "disk" "$mount_point" "$size_kb" "$used_pct"
done

# ---------------------------------------------------------------
# 6. 主要パッケージのバージョン
#    dpkg-query(Debian/Ubuntu系)と rpm(RHEL系)の両方に対応する。
#    「入っていない」ことも構成情報なので not_installed として明示的に出す。
#    黙って行を出さないと、差分検知側で「取得漏れ」と区別できなくなる。
# ---------------------------------------------------------------
if command -v dpkg-query >/dev/null 2>&1; then
    for pkg in $WATCH_PACKAGES; do
        pkg_ver="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null)"
        emit "package" "$pkg" "${pkg_ver:-not_installed}"
    done
elif command -v rpm >/dev/null 2>&1; then
    for pkg in $WATCH_PACKAGES; do
        pkg_ver="$(rpm -q --qf '%{VERSION}-%{RELEASE}' "$pkg" 2>/dev/null)"
        emit "package" "$pkg" "${pkg_ver:-not_installed}"
    done
else
    emit_note "package" "no_package_manager"
fi

# ---------------------------------------------------------------
# 7. 起動中のサービス
#    systemctl は systemd が PID 1 として動いている環境でしか使えない。
#    コンテナ等では失敗するので、その場合は note を残して先に進む。
# ---------------------------------------------------------------
if command -v systemctl >/dev/null 2>&1 \
    && systemctl is-system-running >/dev/null 2>&1; then
    systemctl list-units --type=service --state=running \
        --no-legend --no-pager 2>/dev/null \
        | awk '{print $1}' | sort \
        | while read -r svc; do
            [ -n "$svc" ] && emit "service" "$svc"
        done
else
    emit_note "service" "systemd_unavailable"
fi

# ---------------------------------------------------------------
# 8. 一般ユーザー一覧
#    UID 1000以上65534未満が、慣習的に「人間が使う一般ユーザー」の範囲。
#    (0はroot、1〜999はサービス用、65534はnobody)
#    ログインシェルも一緒に取る。/usr/sbin/nologin から /bin/bash への
#    変更は「ログインできない口が開いた」ことを意味する重要な差分。
# ---------------------------------------------------------------
getent passwd 2>/dev/null \
    | awk -F: '$3 >= 1000 && $3 < 65534 {print $1 "\t" $3 "\t" $7}' \
    | sort \
    | while IFS=$'\t' read -r uname_ uid_ shell_; do
        emit "user" "$uname_" "$uid_" "$shell_"
    done

# ---------------------------------------------------------------
# 9. 管理者権限(sudo)を持つユーザー
#    Debian/Ubuntu系は sudo グループ、RHEL系は wheel グループが該当する。
#    「誰が管理者権限を持っているか」は、台帳項目の中でも
#    最もセキュリティ上重要な情報なので、独立した項目として収集する。
# ---------------------------------------------------------------
for admin_group in sudo wheel; do
    group_line="$(getent group "$admin_group" 2>/dev/null)"
    [ -z "$group_line" ] && continue
    # getent group の出力例: sudo:x:27:ubuntu,deploy
    members="${group_line##*:}"
    [ -z "$members" ] && continue
    printf '%s\n' "$members" | tr ',' '\n' | sort -u \
        | while read -r member; do
            [ -n "$member" ] && emit "sudoer" "$member"
        done
done

# ---------------------------------------------------------------
# 10. 待ち受け中(LISTEN)のTCPポート
#     ss → netstat → /proc/net/tcp の順にフォールバックする。
#     最後の /proc/net/tcp は、追加コマンドが一切ない最小環境でも
#     読める Linux カーネルの情報源。
# ---------------------------------------------------------------
list_ports_from_proc() {
    # /proc/net/tcp の書式(抜粋):
    #   sl local_address rem_address st ...
    #   0: 0100007F:9935 00000000:0000 0A ...
    # local_address は "IPアドレス:ポート番号" を16進数で表したもの。
    # st(状態)が "0A" の行が LISTEN 状態を表す。
    local file
    for file in /proc/net/tcp /proc/net/tcp6; do
        [ -r "$file" ] || continue
        # 1行目はヘッダーなので tail で読み飛ばす。
        tail -n +2 "$file" | while read -r _ local_addr _ state _; do
            [ "$state" = "0A" ] || continue
            hex_port="${local_addr##*:}"     # ":" より後ろ = ポート番号(16進)
            # printf '%d' に 0x付き文字列を渡すと10進数に変換できる。
            printf '%d\n' "0x${hex_port}" 2>/dev/null
        done
    done
}

if command -v ss >/dev/null 2>&1; then
    # -H: ヘッダー行を出さない / -t: TCP / -l: LISTENのみ / -n: 名前解決しない
    ss -H -tln 2>/dev/null | awk '{n=split($4, a, ":"); print a[n]}' \
        | sort -n -u | while read -r port; do
            [ -n "$port" ] && emit "port" "$port"
        done
elif command -v netstat >/dev/null 2>&1; then
    netstat -tln 2>/dev/null | awk '/^tcp/ {n=split($4, a, ":"); print a[n]}' \
        | sort -n -u | while read -r port; do
            [ -n "$port" ] && emit "port" "$port"
        done
elif [ -r /proc/net/tcp ]; then
    list_ports_from_proc | sort -n -u | while read -r port; do
        [ -n "$port" ] && emit "port" "$port"
    done
    emit_note "port" "used_proc_net_tcp_fallback"
else
    emit_note "port" "unavailable"
fi

exit 0
