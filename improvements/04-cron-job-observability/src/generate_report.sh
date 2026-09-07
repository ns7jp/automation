#!/usr/bin/env bash
#
# =====================================================================
# generate_report.sh
# 改善案件No.4: cronのサイレント障害を実行結果の可視化と失敗検知で撲滅
#   - 実行状況レポート(Markdown)生成スクリプト
#
# 概要:
#   実行記録CSV(records.csv)を集計し、
#   「どのジョブが、何回動いて、何回失敗したか」を1枚のMarkdownにまとめる。
#
#   失敗の即時通知が「点」の情報だとすれば、このレポートは「線」の情報。
#     - 通知は消えていくが、レポートは残る(台帳・エビデンスになる)
#     - 「毎日1回は必ず失敗している」といった慢性的な傾向に気づける
#     - 台帳(jobs.conf)に載っていないジョブが動いていれば発見できる
#
# 使い方:
#   generate_report.sh [対象日]
#
#   対象日は date コマンドが解釈できる形式で指定する(既定: today)。
#     例) generate_report.sh              # 今日の分
#         generate_report.sh yesterday    # 昨日の分
#         generate_report.sh 2026-09-06   # 日付を直接指定
#
# 出力:
#   ${REPORT_DIR}/<YYYY-MM-DD>.md  … 日付ごとのレポート
#   ${REPORT_DIR}/latest.md        … 最新のレポート(同じ内容のコピー)
#
# 終了ステータス:
#   0  : 正常終了
#   90 : 設定ファイル・台帳が見つからないなどのエラー
#   91 : 引数(対象日)の指定誤り
#
# 前提:
#   同じディレクトリに job_observability.conf が配置されていること。
#   (環境変数 JOBOBS_CONF で別のファイルを指定することもできる)
# =====================================================================

set -u

# ----------------------------------------------------------------
# 設定ファイルの読み込み
# ----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${JOBOBS_CONF:-${SCRIPT_DIR}/job_observability.conf}"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "[ERROR] 設定ファイルが見つかりません: ${CONFIG_FILE}" >&2
    exit 90
fi

# shellcheck source=job_observability.conf
source "$CONFIG_FILE"

if [ ! -f "$JOBS_FILE" ]; then
    echo "[ERROR] ジョブ台帳が見つかりません: ${JOBS_FILE}" >&2
    exit 90
fi

if [ ! -f "$RECORD_FILE" ]; then
    echo "[ERROR] 実行記録CSVが見つかりません: ${RECORD_FILE}" >&2
    exit 90
fi

# ----------------------------------------------------------------
# 対象日の決定
# ----------------------------------------------------------------
# date -d は "yesterday" や "2026-09-06" のような表現を解釈できる。
# 解釈できない文字列を渡された場合はここで止める。
DATE_SPEC="${1:-today}"

if ! TARGET_DATE="$(date -d "$DATE_SPEC" '+%Y-%m-%d' 2>/dev/null)"; then
    echo "[ERROR] 対象日として解釈できません: ${DATE_SPEC}" >&2
    echo "  例: $(basename "$0") yesterday / $(basename "$0") 2026-09-06" >&2
    exit 91
fi

mkdir -p "$REPORT_DIR" || exit 90
REPORT_FILE="${REPORT_DIR}/${TARGET_DATE}.md"
GENERATED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
HOSTNAME_SHORT="$(hostname -s 2>/dev/null || echo unknown)"

# ----------------------------------------------------------------
# ジョブ台帳の読み込み
# ----------------------------------------------------------------
# 台帳の内容を配列に読み込んでおき、後の集計で何度でも使えるようにする。
# 想定実行間隔・猶予時間はデッドマン監視だけが使う項目なので、
# ここでは「_」という名前の変数に読み捨てている(使わないことを明示する書き方)。
JOB_IDS=()
JOB_DESCS=()
JOB_ENABLED=()

while IFS=',' read -r job_id _ _ enabled description <&3; do
    [ -n "$job_id" ] || continue
    JOB_IDS+=("$job_id")
    JOB_ENABLED+=("$enabled")
    JOB_DESCS+=("$description")
done 3< <(sed -e 's/#.*$//' \
              -e 's/^[[:space:]]*//' \
              -e 's/[[:space:]]*$//' \
              -e 's/[[:space:]]*,[[:space:]]*/,/g' \
              -e '/^$/d' "$JOBS_FILE")

# ----------------------------------------------------------------
# 全体サマリの集計
# ----------------------------------------------------------------
# substr($1, 1, 10) は開始時刻(ISO形式)の先頭10文字 = 日付部分。
# ISO形式("2026-09-07T03:00:01+0900")は先頭から日付が並んでいるため、
# 文字列の切り出しと比較だけで日付の絞り込みができる。
SUMMARY_LINE="$(awk -F',' -v d="$TARGET_DATE" '
    NR == 1 { next }
    substr($1, 1, 10) != d { next }
    { total++ }
    $4 == "SUCCESS" { ok++ }
    $4 == "FAILED"  { ng++ }
    $4 == "SKIPPED" { skip++ }
    END { printf "%d\t%d\t%d\t%d\n", total, ok, ng, skip }
' "$RECORD_FILE")"

IFS=$'\t' read -r TOTAL_ALL OK_ALL NG_ALL SKIP_ALL <<< "$SUMMARY_LINE"

# 記録に登場するホスト名を重複なく並べる。
# 将来、複数サーバーの記録を1つのCSVに集約する運用にしても
# レポートの見出しが正しくなるよう、実行中のホスト名ではなく記録側から取る。
REPORT_HOSTS="$(awk -F',' -v d="$TARGET_DATE" \
    'NR > 1 && substr($1, 1, 10) == d { print $7 }' "$RECORD_FILE" \
    | sort -u \
    | awk 'BEGIN { ORS = "" } { if (NR > 1) printf ", "; print }')"

if [ -z "$REPORT_HOSTS" ]; then
    REPORT_HOSTS="$HOSTNAME_SHORT"
fi

# ----------------------------------------------------------------
# レポートの見出し部分を出力する(ここでファイルを新規作成する)
# ----------------------------------------------------------------
cat > "$REPORT_FILE" <<EOF
# cronジョブ実行状況レポート ${TARGET_DATE}

| 項目 | 内容 |
|---|---|
| 対象日 | ${TARGET_DATE} 00:00:00 〜 23:59:59 |
| 対象ホスト | ${REPORT_HOSTS} |
| 生成日時 | ${GENERATED_AT} |
| 集計元 | \`${RECORD_FILE}\` |
| ジョブ台帳 | \`${JOBS_FILE}\` |

## サマリ

| 項目 | 件数 |
|---|---|
| 総実行回数 | ${TOTAL_ALL} |
| 成功(SUCCESS) | ${OK_ALL} |
| 失敗(FAILED) | ${NG_ALL} |
| 多重起動によるスキップ(SKIPPED) | ${SKIP_ALL} |

## ジョブ別の実行状況

| 状態 | ジョブID | 説明 | 実行 | 成功 | 失敗 | スキップ | 最終実行 | 最終結果 | 平均所要(秒) | 最大所要(秒) |
|---|---|---|---|---|---|---|---|---|---|---|
EOF

# ----------------------------------------------------------------
# ジョブごとの集計とテーブル行の出力
# ----------------------------------------------------------------
NO_RUN_JOBS=""

for i in "${!JOB_IDS[@]}"; do
    job_id="${JOB_IDS[$i]}"

    # 監視対象外(enabled=no)のジョブは一覧に出さない
    [ "${JOB_ENABLED[$i]}" = "yes" ] || continue

    # 1ジョブ分の集計をawkで一気に行う。
    # ここでは「読みやすさ」を優先し、ジョブごとにCSVを読み直している。
    # (対象は8本程度・記録も1日数百行のため、性能上の問題は起きない)
    stats_line="$(awk -F',' -v id="$job_id" -v d="$TARGET_DATE" '
        NR == 1 { next }
        substr($1, 1, 10) != d { next }
        $3 != id { next }
        { total++ }
        $1 > last_at { last_at = $1; last_status = $4 }
        $4 == "SUCCESS" { ok++ }
        $4 == "FAILED"  { ng++ }
        $4 == "SKIPPED" { skip++ }
        $4 != "SKIPPED" {
            sec = $6 + 0
            sum += sec
            n++
            if (sec > max) { max = sec }
        }
        END {
            printf "%d\t%d\t%d\t%d\t%s\t%s\t%s\t%s\n",
                total, ok, ng, skip,
                (n > 0 ? sprintf("%.1f", sum / n) : "-"),
                (n > 0 ? sprintf("%d", max) : "-"),
                (last_at != "" ? substr(last_at, 12, 8) : "-"),
                (last_status != "" ? last_status : "-")
        }
    ' "$RECORD_FILE")"

    IFS=$'\t' read -r total ok ng skip avg max last_at last_status <<< "$stats_line"

    # 状態アイコン: 失敗が1回でもあれば赤、スキップがあれば黄、
    # 1回も実行されていなければ白、それ以外は緑
    if [ "$total" -eq 0 ]; then
        icon="⚪ 未実行"
        NO_RUN_JOBS="${NO_RUN_JOBS}${job_id}"$'\n'
    elif [ "$ng" -gt 0 ]; then
        icon="🔴 失敗あり"
    elif [ "$skip" -gt 0 ]; then
        icon="🟡 スキップあり"
    else
        icon="🟢 正常"
    fi

    printf '| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n' \
        "$icon" "$job_id" "${JOB_DESCS[$i]}" "$total" "$ok" "$ng" "$skip" \
        "$last_at" "$last_status" "$avg" "$max" >> "$REPORT_FILE"
done

# ----------------------------------------------------------------
# 未実行ジョブ / 台帳に無いジョブの一覧
# ----------------------------------------------------------------
{
    echo ""
    echo "## 対象日に一度も実行されなかったジョブ"
    echo ""
} >> "$REPORT_FILE"

if [ -z "$NO_RUN_JOBS" ]; then
    echo "台帳に登録されたジョブは、すべて対象日に1回以上実行されている。" >> "$REPORT_FILE"
else
    {
        echo "次のジョブは台帳に登録されているが、対象日の実行記録が無い。"
        echo "週次・平日のみなど、そもそも毎日動かないジョブでなければ調査が必要。"
        echo ""
        printf '%s' "$NO_RUN_JOBS" | while IFS= read -r id; do
            [ -n "$id" ] && echo "- \`${id}\`"
        done
    } >> "$REPORT_FILE"
fi

# 実行記録にはあるが台帳(jobs.conf)に無いジョブ = 「野良ジョブ」の検出。
# 誰かが台帳を更新せずにcronを追加した場合にここで炙り出せる。
{
    echo ""
    echo "## 台帳に登録されていないジョブ"
    echo ""
} >> "$REPORT_FILE"

UNKNOWN_FOUND="no"
RECORDED_IDS="$(awk -F',' -v d="$TARGET_DATE" \
    'NR > 1 && substr($1, 1, 10) == d { print $3 }' "$RECORD_FILE" | sort -u)"

while IFS= read -r recorded_id; do
    [ -n "$recorded_id" ] || continue
    known="no"
    for known_id in "${JOB_IDS[@]}"; do
        if [ "$recorded_id" = "$known_id" ]; then
            known="yes"
            break
        fi
    done
    if [ "$known" = "no" ]; then
        if [ "$UNKNOWN_FOUND" = "no" ]; then
            {
                echo "実行記録はあるが jobs.conf に登録が無いジョブが見つかった。"
                echo "台帳への追記漏れか、把握されていないcron設定の可能性がある。"
                echo ""
            } >> "$REPORT_FILE"
            UNKNOWN_FOUND="yes"
        fi
        echo "- \`${recorded_id}\`" >> "$REPORT_FILE"
    fi
done <<< "$RECORDED_IDS"

if [ "$UNKNOWN_FOUND" = "no" ]; then
    echo "台帳に無いジョブの実行記録は見つからなかった。" >> "$REPORT_FILE"
fi

# ----------------------------------------------------------------
# 凡例と締め
# ----------------------------------------------------------------
cat >> "$REPORT_FILE" <<EOF

## 状態アイコンの見方

| アイコン | 意味 |
|---|---|
| 🟢 正常 | 対象日の実行がすべて成功した |
| 🟡 スキップあり | 前回の実行が終わらず、多重起動を防ぐためスキップされた回がある |
| 🔴 失敗あり | 終了ステータスが0以外で終わった回がある(通知済み) |
| ⚪ 未実行 | 対象日の実行記録が1件も無い |

## 補足

- 「最終実行」は対象日の中で最後に開始された時刻(時:分:秒)。
- 「平均所要」「最大所要」はスキップされた回を除いて計算している。
- このレポートは \`generate_report.sh\` により自動生成される(既定では毎日07:10に前日分)。
EOF

# 「最新のレポート」を毎回同じパスから読めるようにコピーしておく。
# シンボリックリンクではなくコピーにしているのは、
# レポートを別サーバーへ転送する運用にしたときも扱いを単純にするため。
cp "$REPORT_FILE" "${REPORT_DIR}/latest.md"

echo "レポートを生成しました: ${REPORT_FILE}"
echo "最新版へのコピー: ${REPORT_DIR}/latest.md"

exit 0
