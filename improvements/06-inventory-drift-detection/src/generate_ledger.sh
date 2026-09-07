#!/usr/bin/env bash
#
# =====================================================================
# generate_ledger.sh
# 改善案件No.6: サーバー台帳の自動収集・差分検知 - 台帳生成スクリプト
#
# 概要:
#   最新のスナップショット(JSON)から、人間が読むためのサーバー台帳を
#   2種類の形式で自動生成する。
#     - Markdown版(ledger.md) … GitHubやWikiでそのまま読める一覧+詳細
#     - CSV版(ledger.csv)     … Excel・スプレッドシートで開ける一覧
#
# なぜ2形式なのか:
#   改善前の運用がExcel台帳だったため、いきなりMarkdownだけにすると
#   現場が使えなくなる。「今までどおりExcelでも見られる」出口を残すことで、
#   移行のハードルを下げる狙いがある(=改善案件では“使われる形”が重要)。
#
# 重要な考え方:
#   生成された台帳は「手で編集してはいけない」。手で直すと、次回の実行で
#   上書きされて消える。台帳は常に「収集結果から作り直されるもの」であり、
#   これこそが「台帳が実態から乖離しなくなる」仕組みそのものである。
#
# 使い方:
#   ./generate_ledger.sh                     # 最新スナップショットから生成
#   ./generate_ledger.sh --date 2026-09-01   # 指定日の台帳を再現する
#   ./generate_ledger.sh --config ./test.conf
#
# 終了コード:
#   0 : 生成成功 / 1 : エラー
# =====================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/inventory.conf"
TARGET_DATE=""

usage() {
    cat <<'USAGE'
使い方: generate_ledger.sh [オプション]

  --config <ファイル>   設定ファイルのパス(既定: 同じ場所の inventory.conf)
  --date <YYYY-MM-DD>   台帳を作る対象日(既定: 最新のスナップショット)
  --help                このヘルプを表示する
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --config) CONFIG_FILE="${2:-}"; shift 2 || true ;;
        --date)   TARGET_DATE="${2:-}"; shift 2 || true ;;
        --help|-h) usage; exit 0 ;;
        *)
            echo "[ERROR] 不明なオプション: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [ ! -f "$CONFIG_FILE" ]; then
    echo "[ERROR] 設定ファイルが見つかりません: ${CONFIG_FILE}" >&2
    exit 1
fi
# shellcheck source=inventory.conf
source "$CONFIG_FILE"

if ! command -v jq >/dev/null 2>&1; then
    echo "[ERROR] jq が見つかりません。'sudo apt install jq' でインストールしてください" >&2
    exit 1
fi

mkdir -p "$REPORT_DIR" "$(dirname "$LOG_FILE")" || {
    echo "[ERROR] 出力先ディレクトリを作成できません(権限を確認してください)" >&2
    exit 1
}

log() {
    local level="$1"
    shift
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" \
        | tee -a "$LOG_FILE"
}

# ---------------------------------------------------------------
# 対象日の決定
# ---------------------------------------------------------------
if [ -z "$TARGET_DATE" ]; then
    TARGET_DATE="$(find "$SNAPSHOT_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
        | sort | tail -n 1)"
fi

SNAPSHOT_DIR="${SNAPSHOT_ROOT}/${TARGET_DATE}"
if [ ! -d "$SNAPSHOT_DIR" ]; then
    echo "[ERROR] 指定日のスナップショットがありません: ${SNAPSHOT_DIR}" >&2
    exit 1
fi

mapfile -t json_files < <(find "$SNAPSHOT_DIR" -maxdepth 1 -name '*.json' | sort)
if [ "${#json_files[@]}" -eq 0 ]; then
    echo "[ERROR] スナップショットJSONが1件もありません: ${SNAPSHOT_DIR}" >&2
    exit 1
fi

LEDGER_MD="${REPORT_DIR}/ledger.md"
LEDGER_CSV="${REPORT_DIR}/ledger.csv"
HISTORY_CSV="${REPORT_DIR}/drift-history.csv"

log "INFO" "===== 台帳の生成を開始します (対象日: ${TARGET_DATE}, ${#json_files[@]} 台) ====="

# ---------------------------------------------------------------
# Markdown台帳: 一覧表
#
# jq の -r は「結果を生の文字列として出す」オプション(引用符を付けない)。
# \(...) は文字列の中に式の結果を埋め込む書き方(文字列補間)。
# status が "ok" でないホストは、facts が null になるため "-" を表示する。
# ---------------------------------------------------------------
SUMMARY_ROW_JQ='
"| \(.host) | \(.role) | \(.facts.hostname // "-") | \(.facts.os.name // "-") | " +
"\(.facts.kernel // "-") | \((.facts.ip_addresses // []) | join(" ")) | " +
"\((.facts.ports // []) | map(tostring) | join(" ")) | " +
"\(if .status == "ok" then "OK" else "収集失敗" end) |"
'

{
    echo "# サーバー台帳(自動生成)"
    echo
    echo "> **このファイルは \`generate_ledger.sh\` が自動生成しています。手で編集しないでください。**"
    echo "> 手で書き換えても次回の実行で上書きされます。内容を変えたい場合は、"
    echo "> サーバー側の実際の構成を変えるか、収集項目の設定を変更してください。"
    echo
    echo "| 項目 | 内容 |"
    echo "|---|---|"
    echo "| 管理組織 | ${COMPANY_NAME}(架空の依頼元) |"
    echo "| 管理担当 | ${LEDGER_AUTHOR} |"
    echo "| 情報の基準日 | ${TARGET_DATE} |"
    echo "| 生成日時 | $(date '+%Y-%m-%d %H:%M:%S') |"
    echo "| 対象サーバー数 | ${#json_files[@]} 台 |"
    echo
    echo "## 1. サーバー一覧"
    echo
    echo "| 名前 | 役割 | ホスト名 | OS | カーネル | IPアドレス | 待受ポート | 収集状態 |"
    echo "|---|---|---|---|---|---|---|---|"
    jq -r "$SUMMARY_ROW_JQ" "${json_files[@]}"
    echo
    echo "## 2. サーバー別の詳細"
    echo
} > "$LEDGER_MD"

# ---------------------------------------------------------------
# Markdown台帳: サーバーごとの詳細
# ---------------------------------------------------------------
DETAIL_JQ='
"### \(.host)(\(.role))\n" +
"\n" +
"| 項目 | 値 |\n" +
"|---|---|\n" +
"| ホスト名 | \(.facts.hostname // "-") |\n" +
"| OS | \(.facts.os.name // "-") |\n" +
"| カーネル | \(.facts.kernel // "-") |\n" +
"| アーキテクチャ | \(.facts.arch // "-") |\n" +
"| IPアドレス | \((.facts.ip_addresses // []) | join(", ")) |\n" +
"| 収集日時 | \(.collected_at) |\n" +
"| 収集状態 | \(.status) |\n" +
"\n" +
"**ディスク**\n\n" +
"| マウント | 容量(GB) | 使用率(%) |\n" +
"|---|---|---|\n" +
((.facts.disks // [])
  | map("| \(.mount) | \((.size_kb / 1048576 * 10 | round) / 10) | \(.used_percent) |")
  | join("\n")) +
"\n\n" +
"**主要パッケージ**\n\n" +
"| パッケージ | バージョン |\n" +
"|---|---|\n" +
((.facts.packages // [])
  | map("| \(.name) | \(.version) |")
  | join("\n")) +
"\n\n" +
"**一般ユーザー**(UID 1000以上)\n\n" +
"| ユーザー名 | UID | ログインシェル | sudo権限 |\n" +
"|---|---|---|---|\n" +
(. as $doc
 | (.facts.users // [])
 | map(. as $u
       | "| \($u.name) | \($u.uid) | \($u.shell) | " +
         (if (($doc.facts.sudoers // []) | index($u.name)) then "あり" else "なし" end) + " |")
 | join("\n")) +
"\n\n" +
"**起動中サービス**: " +
(if ((.facts.services // []) | length) == 0
 then "(取得できませんでした)"
 else ((.facts.services // []) | join(", ")) end) +
"\n\n" +
"**待受TCPポート**: " +
((.facts.ports // []) | map(tostring) | join(", ")) +
"\n\n" +
(if ((.notes // []) | length) > 0
 then "**収集時の注意**: " + ((.notes // []) | map("\(.item)=\(.reason)") | join(", ")) + "\n\n"
 else "" end)
'

jq -r "$DETAIL_JQ" "${json_files[@]}" >> "$LEDGER_MD"

# ---------------------------------------------------------------
# Markdown台帳: 直近の構成変更履歴
#
# 「台帳」と「変更履歴」を1枚にまとめておくと、
# 「今こうなっている」だけでなく「最近こう変わった」まで一目で分かる。
# ---------------------------------------------------------------
{
    echo "## 3. 直近の構成変更(最新10件)"
    echo
    if [ -f "$HISTORY_CSV" ] && [ "$(wc -l < "$HISTORY_CSV")" -gt 1 ]; then
        echo "| 検知日 | サーバー | 項目 | 変更種別 | 変更前 | 変更後 | 重要度 |"
        echo "|---|---|---|---|---|---|---|"
        # tail -n +2 でヘッダー行を飛ばし、tail -n 10 で末尾10件を取る。
        tail -n +2 "$HISTORY_CSV" | tail -n 10 | while IFS=, read -r d h k c b a s; do
            echo "| ${d} | ${h} | \`${k}\` | ${c} | ${b} | ${a} | ${s} |"
        done
    else
        echo "変更履歴はまだありません(初回収集直後、または差分なし)。"
    fi
    echo
    echo "---"
    echo
    echo "本台帳は generate_ledger.sh により、${TARGET_DATE} のスナップショットから自動生成されました。"
} >> "$LEDGER_MD"

log "INFO" "Markdown台帳を出力しました: ${LEDGER_MD}"

# ---------------------------------------------------------------
# CSV台帳
#
# @csv は「配列をCSVの1行に変換し、必要な引用符とエスケープを自動で付ける」
# jq の機能。カンマを含む値があっても壊れないため、自分で "," を連結するより安全。
# 複数値の項目(IPやポート)はセル内で ";" 区切りにまとめている。
# ---------------------------------------------------------------
CSV_JQ='
[ .host,
  .role,
  (.facts.hostname // "-"),
  (.facts.os.name // "-"),
  (.facts.kernel // "-"),
  (.facts.arch // "-"),
  ((.facts.ip_addresses // []) | join(";")),
  ((.facts.disks // []) | map("\(.mount)=\((.size_kb / 1048576 * 10 | round) / 10)GB") | join(";")),
  ((.facts.packages // []) | map("\(.name)=\(.version)") | join(";")),
  ((.facts.users // []) | map(.name) | join(";")),
  ((.facts.sudoers // []) | join(";")),
  ((.facts.ports // []) | map(tostring) | join(";")),
  .collected_at,
  .status
] | @csv
'

{
    echo "name,role,hostname,os,kernel,arch,ip_addresses,disks,packages,users,sudoers,listen_ports,collected_at,status"
    jq -r "$CSV_JQ" "${json_files[@]}"
} > "$LEDGER_CSV"

log "INFO" "CSV台帳を出力しました: ${LEDGER_CSV}"
log "INFO" "===== 台帳の生成が完了しました ====="

exit 0
