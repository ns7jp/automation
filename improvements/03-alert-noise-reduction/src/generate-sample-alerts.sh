#!/usr/bin/env bash
# =====================================================================
# generate-sample-alerts.sh
# 改善案件No.3: アラート過多の改善 - サンプル通知ログ生成スクリプト
#
# ■ 何をするスクリプトか
#   「改善前(As-Is)の1日分の通知ログ」を再現したサンプルを生成する。
#   1日あたりちょうど200件、内訳は 01-current-analysis.md の
#   棚卸し表と完全に一致するように作ってある。
#
# ■ なぜ必要か
#   改善案件は「まず現状を数える」ところから始まる。しかし学習用の
#   手元環境には、当然ながら過去の通知ログが存在しない。
#   このスクリプトで検証用のログを作ることで、棚卸し → 分類 →
#   効果測定という一連の流れを、誰でも自分の手元で再現できる。
#
# ■ 出力形式(タブ区切り。alert-router.sh --replay がそのまま読める)
#   発生日時<TAB>発生元<TAB>ホスト名<TAB>通知本文
#
#   通知本文は projects/02, projects/03, projects/04 が実際に
#   Slackへ送っている文面に合わせてある。
#   案件No.3のログ監視ツールの通知は本来複数行だが、取り込み時に
#   1行へ整形される仕様なので、ここでも1行で表現している。
#
# ■ 使い方
#   ./generate-sample-alerts.sh                      # 昨日1日分を生成
#   ./generate-sample-alerts.sh --date 2026-09-01    # 日付を指定
#   ./generate-sample-alerts.sh --days 14            # 14日分を生成
#   ./generate-sample-alerts.sh --out /tmp/alerts.tsv
#
# ■ 再現性について
#   乱数は自前の簡易な計算式(線形合同法)で作っている。Bash 組み込みの
#   $RANDOM はバージョンによって出る値が変わるため、「誰が実行しても
#   まったく同じログができる」ことを保証したいこの用途には使えない。
#   同じ --seed を指定すれば、環境が違っても必ず同じ結果になる。
#
# ■ 依存コマンド: bash 4.0以降, date, sort
# =====================================================================

set -uo pipefail

OUT_FILE="./sample-alerts.tsv"
START_DATE=""
DAYS=1
SEED=20260901

usage() {
    cat <<'USAGE'
使い方: generate-sample-alerts.sh [オプション]

オプション:
  --date <YYYY-MM-DD>  開始日(省略時は昨日)
  --days <N>           生成する日数(既定 1)
  --out <ファイル>     出力先(既定 ./sample-alerts.tsv)
  --seed <整数>        乱数の種(既定 20260901)。同じ値なら同じ結果になる
  -h, --help           このヘルプを表示する
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --date) START_DATE="${2:-}"; shift 2 ;;
        --days) DAYS="${2:-1}"; shift 2 ;;
        --out)  OUT_FILE="${2:-}"; shift 2 ;;
        --seed) SEED="${2:-0}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) printf '[ERROR] 不明なオプションです: %s\n' "$1" >&2; usage >&2; exit 1 ;;
    esac
done

if [[ -z "$START_DATE" ]]; then
    START_DATE="$(date -d 'yesterday' '+%Y-%m-%d')"
fi
if ! [[ "$DAYS" =~ ^[1-9][0-9]*$ ]]; then
    printf '[ERROR] --days は1以上の整数で指定してください: %s\n' "$DAYS" >&2
    exit 1
fi

# ---------------------------------------------------------------------
# 簡易乱数(線形合同法)
#   x(n+1) = (x(n) * 1103515245 + 12345) mod 2^31
# 暗号用途には使えないが、「毎回同じ順序で、ばらついた数値が欲しい」
# という今回の用途にはこれで十分。掛け算の結果は最大でも約2.4e18で、
# Bashの整数(64bit)の範囲に収まるためオーバーフローしない。
# ---------------------------------------------------------------------
RAND_STATE=0

rand_seed() { RAND_STATE="$1"; }

rand_below() {
    local max="$1"
    RAND_STATE=$(( (RAND_STATE * 1103515245 + 12345) % 2147483648 ))
    printf '%s' $(( RAND_STATE % max ))
}

# ---------------------------------------------------------------------
# 1件分の通知を出力する
#   $1: その日の0時からの経過秒数
#   $2: 発生元 / $3: ホスト名 / $4: 通知本文 / $5: 集計用のカテゴリ名
# ---------------------------------------------------------------------
declare -A CATEGORY_COUNT=()
CATEGORY_ORDER=()
TOTAL=0
BASE_EPOCH=0
TMP_FILE=""

emit() {
    local sod="$1" src="$2" host="$3" msg="$4" category="$5"
    local ts

    ts="$(date -d "@$((BASE_EPOCH + sod))" '+%Y-%m-%d %H:%M:%S')"
    printf '%s\t%s\t%s\t%s\n' "$ts" "$src" "$host" "$msg" >>"$TMP_FILE"

    if [[ -z "${CATEGORY_COUNT[$category]:-}" ]]; then
        CATEGORY_ORDER+=("$category")
        CATEGORY_COUNT["$category"]=0
    fi
    CATEGORY_COUNT["$category"]=$(( CATEGORY_COUNT[$category] + 1 ))
    TOTAL=$((TOTAL + 1))
}

# 秒数を「時:分:秒」から作るための小さなヘルパー
hms() { printf '%s' $(( $1 * 3600 + $2 * 60 + $3 )); }

# ---------------------------------------------------------------------
# 1日分の通知を生成する
#   $1: 対象日(YYYY-MM-DD)/ $2: その日用の乱数の種
# ---------------------------------------------------------------------
generate_one_day() {
    local target_date="$1" day_seed="$2"
    local i host sod rec_sod pct days_left

    BASE_EPOCH="$(date -d "${target_date} 00:00:00" +%s)"
    rand_seed "$day_seed"

    # =================================================================
    # (1) 本番サーバーの死活NG = 本当に対応が必要な障害 … 2件
    #     projects/04-server-health-check の通知形式に合わせている
    # =================================================================
    emit "$(hms 2 14 3)" "health-check" "web01" \
        ":red_circle: [障害検知] web01(http://192.168.1.11/)が2回連続でNGです" "本番死活NG"
    emit "$(hms 14 37 11)" "health-check" "api01" \
        ":red_circle: [障害検知] api01(http://192.168.1.13:8080/healthz)が2回連続でNGです" "本番死活NG"

    # (1') その復旧通知 … 2件(P1発報中のホストなので格上げ対象になる)
    emit "$(hms 2 19 41)" "health-check" "web01" \
        ":white_check_mark: [復旧] web01(http://192.168.1.11/)が復旧しました" "復旧通知"
    emit "$(hms 14 41 55)" "health-check" "api01" \
        ":white_check_mark: [復旧] api01(http://192.168.1.13:8080/healthz)が復旧しました" "復旧通知"

    # =================================================================
    # (2) 非本番サーバーの死活NG(瞬断)とその復旧 … 33件 + 33件
    #     ネットワークの一時的な揺らぎで上がっては戻る、を繰り返す。
    #     アラート疲れの最大の原因のひとつ。
    # =================================================================
    local nonprod_hosts=("batch01" "dev01" "test01")
    local nonprod_ips=("192.168.1.31" "192.168.1.41" "192.168.1.42")
    for (( i = 0; i < 33; i++ )); do
        host="${nonprod_hosts[$(( i % 3 ))]}"
        # 06:00〜23:00 の範囲にばらけさせる
        sod=$(( 21600 + $(rand_below 61200) ))
        emit "$sod" "health-check" "$host" \
            ":red_circle: [障害検知] ${host}(${nonprod_ips[$(( i % 3 ))]})が2回連続でNGです" "非本番死活NG"
        # 1〜5分後に復旧する(=瞬断だった)
        rec_sod=$(( sod + 60 + $(rand_below 240) ))
        emit "$rec_sod" "health-check" "$host" \
            ":white_check_mark: [復旧] ${host}(${nonprod_ips[$(( i % 3 ))]})が復旧しました" "復旧通知"
    done

    # =================================================================
    # (3) アプリログの同一ERROR繰り返し … 62件(6回の障害 × 各6〜15件)
    #     projects/03-log-monitoring-alert の通知形式に合わせている。
    #     本来は複数行だが、取り込み時に1行へ整形される仕様なので
    #     ここでも1行で表現している。
    # =================================================================
    local burst_hosts=("app01" "app02" "web01" "api01" "app01" "batch01")
    local burst_start=(11520 27660 36300 48120 64080 73980)  # 03:12 / 07:41 / 10:05 / 13:22 / 17:48 / 20:33
    local burst_count=(15 12 11 10 8 6)
    local burst_gap=(20 25 30 35 40 45)
    local burst_msg=(
        "ERROR OrderService: payment gateway timeout (order_id=10245)"
        "ERROR SessionStore: redis connection refused (retry=3)"
        "ERROR ImageResizer: temporary file write failed (/tmp full)"
        "ERROR AuthApi: upstream 502 from identity provider"
        "ERROR OrderService: payment gateway timeout (order_id=10891)"
        "ERROR NightlyJob: record 4821 skipped (invalid format)"
    )
    local b j detect_sod detect_ts
    for (( b = 0; b < 6; b++ )); do
        for (( j = 0; j < ${burst_count[$b]}; j++ )); do
            detect_sod=$(( burst_start[b] + j * burst_gap[b] ))
            detect_ts="$(date -d "@$((BASE_EPOCH + detect_sod))" '+%Y-%m-%d %H:%M:%S')"
            emit "$detect_sod" "log-watch" "${burst_hosts[$b]}" \
                ":rotating_light: *ログ異常検知* :rotating_light: ホスト: ${burst_hosts[$b]} 監視対象: /var/log/app/error.log 検知時刻: ${detect_ts} 検知内容(抜粋): ${detect_ts} ${burst_msg[$b]}" \
                "アプリERROR繰り返し"
        done
    done

    # =================================================================
    # (4) バックアップジョブの正常終了通知 … 32件
    #     3時間おき × 4サーバー = 1日32件。すべて「成功しました」の報告。
    #     成功を毎回通知するのは、対応不要な通知を増やす代表例。
    # =================================================================
    local backup_hosts=("web01" "web02" "db01" "app01")
    local backup_hours=(1 4 7 10 13 16 19 22)
    local h
    for h in "${backup_hours[@]}"; do
        for (( i = 0; i < 4; i++ )); do
            emit "$(hms "$h" $(( 5 + i * 3 )) 0)" "backup" "${backup_hosts[$i]}" \
                ":white_check_mark: [バックアップ完了] ${backup_hosts[$i]}-$(date -d "$target_date" '+%Y%m%d').tar.gz を作成しました(12.4MB)" \
                "バックアップ完了"
        done
    done

    # =================================================================
    # (5) ディスク容量警告(閾値70%が低すぎて常時鳴っている) … 19件
    #     projects/02-backup-automation の通知形式に合わせている。
    #     使用率は78〜84%で、実際には何年も同じ水準のまま。
    # =================================================================
    for (( i = 0; i < 19; i++ )); do
        pct=$(( 78 + $(rand_below 7) ))   # 78〜84%
        emit "$(hms "$i" 7 30)" "backup" "backup01" \
            ":warning: [容量警告] バックアップ先(/backup)の使用率が ${pct}% です(閾値: 70%)" \
            "容量警告70-84%"
    done

    # =================================================================
    # (6) ディスク容量警告(85%以上。こちらは本当に確認が必要) … 2件
    # =================================================================
    emit "$(hms 21 5 0)" "backup" "db01" \
        ":warning: [容量警告] バックアップ先(/backup)の使用率が 86% です(閾値: 70%)" "容量警告85%以上"
    emit "$(hms 21 35 0)" "backup" "db01" \
        ":warning: [容量警告] バックアップ先(/backup)の使用率が 88% です(閾値: 70%)" "容量警告85%以上"

    # =================================================================
    # (7) 証明書の期限予告 … 9件
    #     60日前から毎日9ドメイン分が通知される。
    #     まだ余裕があるので、その場での対応は不要。
    # =================================================================
    local cert_domains=(
        "www.example.com" "shop.example.com" "api.example.com"
        "admin.example.com" "img.example.com" "mail.example.com"
        "blog.example.com" "dev.example.com" "stg.example.com"
    )
    local cert_days=(45 38 30 27 22 19 17 16 15)
    for (( i = 0; i < 9; i++ )); do
        days_left="${cert_days[$i]}"
        emit "$(hms 6 $(( 10 + i )) 0)" "cert-check" "cert01" \
            ":information_source: [証明書] ${cert_domains[$i]} の有効期限まで残り ${days_left} 日です" \
            "証明書期限予告"
    done

    # =================================================================
    # (8) 監視ツール自身の再起動通知 … 6件
    # =================================================================
    local monitor_hosts=("app01" "app02" "web01" "web02" "api01" "batch01")
    for (( i = 0; i < 6; i++ )); do
        sod=$(( 3600 + $(rand_below 75600) ))
        emit "$sod" "systemd" "${monitor_hosts[$i]}" \
            ":arrows_counterclockwise: [監視] log-watch-alert サービスを再起動しました" "監視ツール再起動"
    done
}

# ---------------------------------------------------------------------
# メイン処理
# ---------------------------------------------------------------------
TMP_FILE="$(mktemp)"
# trap: スクリプトが途中で終了しても一時ファイルを消す(後片付けの保険)
trap 'rm -f "$TMP_FILE"' EXIT

day_index=0
while (( day_index < DAYS )); do
    current_date="$(date -d "${START_DATE} +${day_index} day" '+%Y-%m-%d')"
    generate_one_day "$current_date" $(( SEED + day_index ))
    day_index=$((day_index + 1))
done

# 発生日時の昇順に並べ替える。
# "YYYY-MM-DD HH:MM:SS" は文字として並べ替えても時系列と一致するため、
# 1列目(タブ区切りの1フィールド目)の辞書順ソートでよい。
mkdir -p "$(dirname "$OUT_FILE")"
sort -t "$(printf '\t')" -k1,1 "$TMP_FILE" >"$OUT_FILE"

# ---------------------------------------------------------------------
# 生成結果のサマリ表示
# ---------------------------------------------------------------------
printf '\nサンプル通知ログを生成しました: %s\n' "$OUT_FILE"
printf '対象期間: %s から %d 日分 / 合計 %d 件(1日あたり %d 件)\n\n' \
    "$START_DATE" "$DAYS" "$TOTAL" $(( TOTAL / DAYS ))
# 日本語は1文字が複数バイトになるため、printf の桁揃え(%-20s など)は
# 文字数ではなくバイト数で数えられてしまい、見た目が揃わない。
# そこで「数値を先に、日本語を後ろに」置くことで確実に揃えている。
printf '  件数  カテゴリ\n'
printf -- '------  --------------------\n'
for category in "${CATEGORY_ORDER[@]}"; do
    printf '%6d  %s\n' "${CATEGORY_COUNT[$category]}" "$category"
done
printf -- '------  --------------------\n'
printf '%6d  %s\n\n' "$TOTAL" "合計"

exit 0
