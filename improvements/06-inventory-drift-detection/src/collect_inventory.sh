#!/usr/bin/env bash
#
# =====================================================================
# collect_inventory.sh
# 改善案件No.6: サーバー台帳の自動収集・差分検知 - 収集スクリプト(管理サーバー側)
#
# 概要:
#   1. targets.conf に列挙された対象サーバーへ、SSH経由(またはローカル)で
#      remote_probe.sh を送り込んで実行する。
#   2. 返ってきたTSV(タブ区切りテキスト)を jq でJSONに組み立てる。
#   3. 日付ごとのディレクトリにスナップショットとして保存する。
#        ${SNAPSHOT_ROOT}/YYYY-MM-DD/<name>.json
#   4. 保持期間を過ぎた古いスナップショットを削除する。
#
# 使い方:
#   ./collect_inventory.sh                      # targets.conf の全台を収集
#   ./collect_inventory.sh --target web01       # 1台だけ収集(段階的導入・切り分け用)
#   ./collect_inventory.sh --config ./test.conf # 設定ファイルを差し替える
#   ./collect_inventory.sh --help
#
# 終了コード:
#   0 : 全台の収集に成功
#   1 : 設定不備など、処理を開始できなかった
#   2 : 1台以上の収集に失敗した(残りの収集は継続している)
# =====================================================================

set -u
# -u : 未定義変数の参照をエラーにする。
# -e は付けない。1台の収集に失敗しても残りの5台の収集は続けたいため、
# 各コマンドの終了コードを自分で確認してハンドリングする方針にしている。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/inventory.conf"
PROBE_SCRIPT="${SCRIPT_DIR}/remote_probe.sh"
ONLY_TARGET=""

# ---------------------------------------------------------------
# コマンドライン引数の解析
# ---------------------------------------------------------------
usage() {
    cat <<'USAGE'
使い方: collect_inventory.sh [オプション]

  --config <ファイル>  設定ファイルのパス(既定: スクリプトと同じ場所の inventory.conf)
  --target <名前>      targets.conf のうち、指定した名前の1台だけを収集する
  --help               このヘルプを表示する
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --config)
            CONFIG_FILE="${2:-}"
            shift 2 || true
            ;;
        --target)
            ONLY_TARGET="${2:-}"
            shift 2 || true
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "[ERROR] 不明なオプション: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------
# 設定ファイルの読み込み
# ---------------------------------------------------------------
if [ ! -f "$CONFIG_FILE" ]; then
    echo "[ERROR] 設定ファイルが見つかりません: ${CONFIG_FILE}" >&2
    exit 1
fi
# shellcheck source=inventory.conf
source "$CONFIG_FILE"

if [ ! -f "$TARGETS_FILE" ]; then
    echo "[ERROR] 対象サーバー定義が見つかりません: ${TARGETS_FILE}" >&2
    exit 1
fi
if [ ! -f "$PROBE_SCRIPT" ]; then
    echo "[ERROR] 収集スクリプトが見つかりません: ${PROBE_SCRIPT}" >&2
    exit 1
fi

# jq は「JSONを作る・整形する・取り出す」ためのコマンド。
# 本ツールの中核なので、無ければ最初に止めて分かりやすいメッセージを出す。
if ! command -v jq >/dev/null 2>&1; then
    echo "[ERROR] jq が見つかりません。'sudo apt install jq' でインストールしてください" >&2
    exit 1
fi

# ---------------------------------------------------------------
# 出力先ディレクトリの準備
# ---------------------------------------------------------------
TODAY="$(date '+%Y-%m-%d')"
SNAPSHOT_DIR="${SNAPSHOT_ROOT}/${TODAY}"
mkdir -p "$SNAPSHOT_DIR" "$(dirname "$LOG_FILE")" || {
    echo "[ERROR] 保存先ディレクトリを作成できません(権限を確認してください)" >&2
    exit 1
}

# ---------------------------------------------------------------
# 共通関数
# ---------------------------------------------------------------

# log: 日時・レベル付きで、画面とログファイルの両方に出力する
log() {
    local level="$1"
    shift
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" \
        | tee -a "$LOG_FILE"
}

# run_probe: 対象サーバー上で remote_probe.sh を実行し、TSVを標準出力に流す
#   引数1: transport(ssh / local)
#   引数2: address(user@host など)
run_probe() {
    local transport="$1"
    local address="$2"

    case "$transport" in
        local)
            # ローカルモード: SSHを使わず、このマシン自身を対象に実行する。
            # SSH接続先を用意できない学習環境でも、ツール全体の流れを
            # そのまま確認できるようにするための逃げ道。
            PROBE_WATCH_PACKAGES="$WATCH_PACKAGES" \
            PROBE_DISK_MOUNTS="$DISK_MOUNTS" \
                timeout "$SSH_COMMAND_TIMEOUT" bash "$PROBE_SCRIPT"
            ;;
        ssh)
            # ssh のオプションの意味:
            #   -o BatchMode=yes
            #       パスワードやパスフレーズを一切聞かない。
            #       cronからの自動実行では「入力待ちで固まる」ことが最悪の事故になるため、
            #       聞く必要が出た時点で即座に失敗させる。
            #   -o ConnectTimeout=N
            #       接続確立までの上限秒数。応答のないサーバーで待ち続けない。
            #   -o StrictHostKeyChecking=accept-new
            #       初回接続のホスト鍵は自動で受け入れるが、
            #       「以前と鍵が変わった」場合は接続を拒否する(なりすまし対策)。
            #   -i <鍵>
            #       収集専用に発行した秘密鍵を明示的に指定する。
            #   timeout コマンド
            #       接続後にコマンドが返ってこない場合の保険(全体の上限時間)。
            #
            # `bash -s` は「標準入力から受け取ったスクリプトを実行する」という意味。
            # これにより、対象サーバーに remote_probe.sh を配置しなくても実行できる。
            timeout "$SSH_COMMAND_TIMEOUT" \
                ssh -o BatchMode=yes \
                    -o ConnectTimeout="$SSH_CONNECT_TIMEOUT" \
                    -o StrictHostKeyChecking=accept-new \
                    -i "$SSH_KEY" \
                    "$address" \
                    "PROBE_WATCH_PACKAGES='${WATCH_PACKAGES}' PROBE_DISK_MOUNTS='${DISK_MOUNTS}' bash -s" \
                    < "$PROBE_SCRIPT"
            ;;
        *)
            echo "[ERROR] 不明な transport: ${transport}" >&2
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------
# TSV → JSON 変換用の jq プログラム
#
# remote_probe.sh が出力するタブ区切りテキストを、構造化されたJSONに
# 組み立てる。ここが「素のテキスト」から「機械で比較できるデータ」への
# 変換点であり、本ツールの心臓部。
#
#   def rows($k) : 1列目が $k である行だけを取り出す(リスト項目用)
#   def val($k)  : 1列目が $k である最初の行の2列目を返す(単一項目用)
# ---------------------------------------------------------------
TSV_TO_JSON_JQ=$(cat <<'JQ_PROGRAM'
def rows($k): map(select(.[0] == $k));
def val($k): (rows($k) | .[0][1]);

# 入力(生テキスト)を行→列に分解する。
# 空行と、タブで分割できなかった行は捨てる。
split("\n")
| map(select(length > 0) | split("\t"))
| {
    schema_version: ((val("schema_version") // "1") | tonumber),
    host: $host,
    role: $role,
    transport: $transport,
    collected_at: $collected_at,
    status: "ok",
    facts: {
      os: {
        name:       (val("os_name")       // "unknown"),
        id:         (val("os_id")         // "unknown"),
        version_id: (val("os_version_id") // "unknown")
      },
      kernel:   (val("kernel")   // "unknown"),
      arch:     (val("arch")     // "unknown"),
      hostname: (val("hostname") // "unknown"),
      ip_addresses: (rows("ip") | map(.[1]) | unique),
      disks: (rows("disk")
              | map({ mount: .[1],
                      size_kb: (.[2] | tonumber),
                      used_percent: (.[3] | tonumber) })
              | sort_by(.mount)),
      packages: (rows("package")
                 | map({ name: .[1], version: .[2] })
                 | sort_by(.name)),
      services: (rows("service") | map(.[1]) | unique),
      users: (rows("user")
              | map({ name: .[1], uid: (.[2] | tonumber), shell: .[3] })
              | sort_by(.name)),
      sudoers: (rows("sudoer") | map(.[1]) | unique),
      ports:   (rows("port") | map(.[1] | tonumber) | unique | sort)
    },
    # notes: 「取得できなかった項目」の記録。
    # 空にせず必ず残すことで、あとから「値が無い」のか
    # 「そもそも取れなかった」のかを区別できる。
    notes: (rows("collect_note") | map({ item: .[1], reason: .[2] }))
  }
JQ_PROGRAM
)

# ---------------------------------------------------------------
# メイン処理: targets.conf を1行ずつ処理する
# ---------------------------------------------------------------
log "INFO" "===== 構成情報の収集を開始します (日付: ${TODAY}) ====="

total=0
success=0
failed=0

# IFS=, で行をカンマ区切りの4項目に分解しながら読む。
# 末尾に改行がないファイルでも最終行を処理できるよう、
# while の条件に「|| [ -n "$name" ]」を付けている。
while IFS=, read -r name transport address role || [ -n "${name:-}" ]; do
    # コメント行(#で始まる)と空行を読み飛ばす
    case "${name:-}" in
        ''|\#*) continue ;;
    esac

    # 前後の空白を取り除く(設定ファイルの書式ゆれ対策)
    name="$(echo "$name" | tr -d '[:space:]')"
    transport="$(echo "$transport" | tr -d '[:space:]')"
    address="$(echo "$address" | tr -d '[:space:]')"
    role="$(echo "${role:-unknown}" | tr -d '[:space:]')"

    # --target が指定されている場合、それ以外はスキップする
    if [ -n "$ONLY_TARGET" ] && [ "$name" != "$ONLY_TARGET" ]; then
        continue
    fi

    total=$((total + 1))
    out_file="${SNAPSHOT_DIR}/${name}.json"
    collected_at="$(date '+%Y-%m-%dT%H:%M:%S%z')"

    log "INFO" "[${name}] 収集開始 (transport=${transport}, address=${address})"

    # 収集結果はいったん一時ファイルに受ける。
    # 直接 out_file に書くと、途中で失敗したとき壊れたJSONが残ってしまうため。
    tmp_tsv="$(mktemp)"
    if ! run_probe "$transport" "$address" > "$tmp_tsv" 2>>"$LOG_FILE"; then
        failed=$((failed + 1))
        log "ERROR" "[${name}] 収集に失敗しました(SSH接続不可・タイムアウト等)"
        # 失敗も「記録として残す」ことが重要。
        # ファイルが無いだけだと、差分検知側で「サーバーが消えた」と
        # 誤解する余地が生まれるため、status=error のJSONを明示的に残す。
        jq -n \
            --arg host "$name" \
            --arg role "$role" \
            --arg transport "$transport" \
            --arg collected_at "$collected_at" \
            '{schema_version: 1, host: $host, role: $role, transport: $transport,
              collected_at: $collected_at, status: "error",
              facts: null, notes: [{item: "collect", reason: "probe_failed"}]}' \
            > "$out_file"
        rm -f "$tmp_tsv"
        continue
    fi

    # TSV → JSON 変換
    #   -R : 入力を「生の文字列」として読む(JSONとして解釈しない)
    #   -s : 入力全体を1つの文字列にまとめる(slurp)
    #   --arg : jqプログラムの中で $host のように参照できる変数を渡す
    if jq -R -s \
        --arg host "$name" \
        --arg role "$role" \
        --arg transport "$transport" \
        --arg collected_at "$collected_at" \
        "$TSV_TO_JSON_JQ" \
        < "$tmp_tsv" > "${out_file}.tmp" 2>>"$LOG_FILE"; then
        mv "${out_file}.tmp" "$out_file"
        success=$((success + 1))
        note_count="$(jq '.notes | length' "$out_file")"
        if [ "$note_count" -gt 0 ]; then
            log "WARN" "[${name}] 収集完了(ただし取得できなかった項目が ${note_count} 件あります)"
        else
            log "INFO" "[${name}] 収集完了 -> ${out_file}"
        fi
    else
        failed=$((failed + 1))
        rm -f "${out_file}.tmp"
        log "ERROR" "[${name}] JSONへの変換に失敗しました(収集結果の形式を確認してください)"
    fi

    rm -f "$tmp_tsv"
done < "$TARGETS_FILE"

# ---------------------------------------------------------------
# 古いスナップショットの削除(世代管理)
#
# find の -mtime +N は「最終更新から N日より古い」という条件。
# ディレクトリ単位で消すため -type d を指定し、
# -maxdepth/-mindepth で「日付ディレクトリの階層だけ」に限定している。
# (指定を誤ると SNAPSHOT_ROOT 自体を消しかねないので、範囲は厳密に絞る)
# ---------------------------------------------------------------
if [ "${SNAPSHOT_RETENTION_DAYS}" -gt 0 ] 2>/dev/null; then
    purged="$(find "$SNAPSHOT_ROOT" -mindepth 1 -maxdepth 1 -type d \
        -mtime "+${SNAPSHOT_RETENTION_DAYS}" -print -exec rm -rf {} + 2>/dev/null | wc -l)"
    if [ "$purged" -gt 0 ]; then
        log "INFO" "保持期間(${SNAPSHOT_RETENTION_DAYS}日)を過ぎたスナップショットを ${purged} 世代削除しました"
    fi
fi

log "INFO" "===== 収集終了: 対象 ${total} 台 / 成功 ${success} 台 / 失敗 ${failed} 台 ====="

if [ "$failed" -gt 0 ]; then
    exit 2
fi
exit 0
