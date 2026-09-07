#!/usr/bin/env bash
# =====================================================================
# common.sh
# 改善案件No.3: アラート過多の改善 - 共通関数ライブラリ
#
# このファイルは単体では実行しない。他のスクリプトから
#   source "${AR_SCRIPT_DIR}/common.sh"
# のように読み込んで使う(=別ファイルに書いた関数を、自分の
# スクリプトの中に取り込んで使えるようにする仕組み)。
#
# なぜ共通化するのか:
#   ログ出力・ルール読み込み・Slack送信といった処理は、
#   alert-router.sh / alert-flush.sh / daily-summary.sh の
#   どれからも使う。同じコードを3か所にコピーすると、直すときに
#   3か所とも直さないといけない(=直し忘れが必ず起きる)。
#   1か所にまとめておけば、修正は1回で済む。
#
# 依存コマンド: date, jq, curl, tr, md5sum, awk, sort
# =====================================================================

# ---------------------------------------------------------------------
# ルール定義を保持する連想配列(=文字列をキーにできる配列)
#
# 通常の配列は 0,1,2... という数字でしか要素を指定できないが、
# 連想配列は RULE_SEVERITY["R010"] のように「ルールID」を
# キーにして値を出し入れできる。ルールIDから重要度を引く、
# という今回の用途にちょうど合う。
#
# declare -A が「連想配列を作る」宣言。Bash 4.0以降で使える
# (Ubuntu 22.04 の Bash 5.1 なら問題なく使える)。
# ---------------------------------------------------------------------
declare -A AR_RULE_PATTERN=()
declare -A AR_RULE_SEVERITY=()
declare -A AR_RULE_CHANNEL=()
declare -A AR_RULE_WINDOW=()
declare -A AR_RULE_DESC=()
# ルールIDを「ファイルに書かれた順番」で覚えておく通常の配列。
# 判定は上から順に行い、最初に一致したルールを採用する
# (=ファイル内の並び順がそのまま優先順位になる)ため、順番が重要。
AR_RULE_IDS=()

# ---------------------------------------------------------------------
# 時刻ユーティリティ
#
# epoch(エポック秒)= 1970年1月1日0時0分0秒(UTC)からの経過秒数。
# 「10分以内かどうか」のような時間の引き算は、この秒数どうしを
# 引き算するのが一番簡単で間違いがない。
# ---------------------------------------------------------------------
ar_now_epoch() { date +%s; }
ar_now_str()   { date '+%Y-%m-%d %H:%M:%S'; }

# エポック秒を人が読める日時文字列に変換する
ar_epoch_to_str() { date -d "@$1" '+%Y-%m-%d %H:%M:%S'; }

# ---------------------------------------------------------------------
# ログ出力
#   $1: ログレベル(INFO / WARN / ERROR)
#   $2以降: メッセージ本文
#
# 画面(標準出力)とログファイルの両方に出す。ERROR だけは
# 標準エラー出力に出すことで、`>/dev/null` で標準出力を捨てても
# エラーだけは画面に残るようにしている。
# ---------------------------------------------------------------------
ar_log() {
    local level="$1"
    shift
    local line
    line="$(printf '[%s] [%s] %s' "$(ar_now_str)" "$level" "$*")"

    # AR_QUIET=true のときは INFO/WARN を画面に出さない(ログファイルには残す)。
    # 過去ログを一括で流し込む検証のとき、画面が流れて見づらくなるのを防ぐため。
    if [[ "$level" == "ERROR" ]]; then
        printf '%s\n' "$line" >&2
    elif [[ "${AR_QUIET:-false}" != "true" ]]; then
        printf '%s\n' "$line"
    fi

    # ログファイルへの書き込みに失敗しても、処理そのものは止めない。
    # 「ログが書けないせいでアラート通知が止まる」のは本末転倒なため。
    if [[ -n "${AR_RUN_LOG:-}" ]]; then
        mkdir -p "$(dirname "$AR_RUN_LOG")" 2>/dev/null || true
        printf '%s\n' "$line" >>"$AR_RUN_LOG" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------
# 必須コマンドの存在確認
#
# なぜ最初に確認するのか: jq が入っていないだけで通知が飛ばなくなる、
# という障害は非常に気づきにくい。起動直後に明確なエラーで止めることで、
# 「動いているつもりで実は動いていない」状態を防ぐ。
# ---------------------------------------------------------------------
ar_require_command() {
    local cmd
    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            ar_log ERROR "コマンド '${cmd}' が見つかりません。インストールしてから再実行してください。"
            return 1
        fi
    done
    return 0
}

# ---------------------------------------------------------------------
# 文字列の正規化(1行化)
#
# 案件No.3のログ監視ツールが出す通知は複数行にまたがる。
# 判定・記録の都合上、改行とタブを半角スペースに置き換えて
# 「1通知 = 1行」に揃えておく。
# (元の複数行のメッセージ自体は、通知本文としてはそのまま使う)
# ---------------------------------------------------------------------
ar_sanitize() {
    printf '%s' "$1" | tr '\n\t' '  '
}

# ---------------------------------------------------------------------
# 文字列をファイル名に使える形へ変換する
#
# 集約キーは "R031:app01" のような文字列で、そのままファイル名に
# するとコロンやスラッシュが問題になる。英数字と ._- 以外を
# すべて "_" に置き換えて安全なファイル名にする。
# ---------------------------------------------------------------------
ar_safe_key() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

# ---------------------------------------------------------------------
# ルール定義ファイルの読み込みと妥当性チェック
#   $1: ルール定義ファイルのパス(省略時は AR_RULES_FILE)
#   戻り値: 0=正常 / 1=定義エラーあり
#
# 書式(パイプ区切り6項目):
#   ルールID|パターン|重要度|通知先|集約ウィンドウ秒|説明
#
# 中核は「パターン|重要度|通知先」の3項目。運用しやすいように
# ルールID・集約ウィンドウ・説明を足して6項目にしている。
# ---------------------------------------------------------------------
ar_load_rules() {
    local file="${1:-${AR_RULES_FILE}}"
    local id pattern severity channel window desc
    local errors=0
    local line_no=0

    if [[ ! -f "$file" ]]; then
        ar_log ERROR "ルール定義ファイルが見つかりません: ${file}"
        return 1
    fi

    # IFS='|' で「区切り文字はパイプ」と指定して1行を6つの変数に分解する。
    # read -r は「バックスラッシュを特殊扱いしない」オプション。
    # 正規表現には \[ のようなバックスラッシュが含まれるため必須。
    while IFS='|' read -r id pattern severity channel window desc; do
        line_no=$((line_no + 1))

        # コメント行(#で始まる)と空行は読み飛ばす
        [[ -z "${id// /}" ]] && continue
        [[ "$id" == \#* ]] && continue

        # --- 妥当性チェック(設定ミスを早期に発見するため) ---
        if [[ -z "$pattern" ]]; then
            ar_log ERROR "ルール定義エラー(${line_no}行目): パターンが空です (id=${id})"
            errors=$((errors + 1))
            continue
        fi
        if [[ "$severity" != "P1" && "$severity" != "P2" && "$severity" != "P3" ]]; then
            ar_log ERROR "ルール定義エラー(${line_no}行目): 重要度は P1/P2/P3 のいずれかです (id=${id}, 値=${severity})"
            errors=$((errors + 1))
            continue
        fi
        if [[ "$channel" != "critical" && "$channel" != "daily" && "$channel" != "record" ]]; then
            ar_log ERROR "ルール定義エラー(${line_no}行目): 通知先は critical/daily/record のいずれかです (id=${id}, 値=${channel})"
            errors=$((errors + 1))
            continue
        fi
        if ! [[ "$window" =~ ^(0|[1-9][0-9]*)$ ]]; then
            ar_log ERROR "ルール定義エラー(${line_no}行目): 集約ウィンドウは0以上の整数です (id=${id}, 値=${window})"
            errors=$((errors + 1))
            continue
        fi
        if [[ -n "${AR_RULE_PATTERN[$id]:-}" ]]; then
            ar_log ERROR "ルール定義エラー(${line_no}行目): ルールID '${id}' が重複しています"
            errors=$((errors + 1))
            continue
        fi

        AR_RULE_IDS+=("$id")
        AR_RULE_PATTERN["$id"]="$pattern"
        AR_RULE_SEVERITY["$id"]="$severity"
        AR_RULE_CHANNEL["$id"]="$channel"
        AR_RULE_WINDOW["$id"]="$window"
        AR_RULE_DESC["$id"]="$desc"
    done <"$file"

    if [[ "$errors" -gt 0 ]]; then
        ar_log ERROR "ルール定義に ${errors} 件の誤りがあります。修正してから再実行してください。"
        return 1
    fi

    ar_log INFO "ルールを ${#AR_RULE_IDS[@]} 件読み込みました: ${file}"
    return 0
}

# ---------------------------------------------------------------------
# メッセージを分類する
#   $1: 1行化済みの通知メッセージ
#   標準出力: "ルールID<TAB>重要度<TAB>通知先<TAB>集約ウィンドウ秒"
#
# ルールは上から順に評価し、最初に一致したものを採用する。
# どのルールにも一致しなかった場合は UNMATCHED とし、重要度は
# AR_UNMATCHED_SEVERITY(既定 P1)にする。
#
# なぜ未分類を P1(最重要)にするのか:
#   「分類できない通知」は、まだ人間が見たことのない新種の通知である
#   可能性が高い。安全側に倒して必ず人の目に触れさせる。
#   これを P3(記録のみ)にしてしまうと、新しい種類の障害が
#   静かに握りつぶされる。フェイルセーフ(=迷ったら安全な側に倒す)の考え方。
#
# 判定に grep ではなく Bash 組み込みの =~ を使っている理由:
#   1通知ごとにルールの数だけ grep プロセスを起動すると、
#   200通知 × 20ルール = 4000回のプロセス起動になり無視できないほど遅い。
#   =~ は Bash 自身が持つ拡張正規表現(ERE)の照合機能で、
#   外部プロセスを起動しないため高速。
# ---------------------------------------------------------------------
ar_classify() {
    local message="$1"
    local id pattern

    for id in "${AR_RULE_IDS[@]}"; do
        pattern="${AR_RULE_PATTERN[$id]}"
        # =~ の右辺は「クォートしない」こと。クォートすると正規表現ではなく
        # ただの文字列として扱われてしまう(Bashの仕様)。
        if [[ $message =~ $pattern ]]; then
            printf '%s\t%s\t%s\t%s\n' \
                "$id" "${AR_RULE_SEVERITY[$id]}" "${AR_RULE_CHANNEL[$id]}" "${AR_RULE_WINDOW[$id]}"
            return 0
        fi
    done

    printf '%s\t%s\t%s\t%s\n' "UNMATCHED" "${AR_UNMATCHED_SEVERITY}" "critical" "0"
    return 0
}

# ---------------------------------------------------------------------
# 送信台帳(outbox)への記録
#   $1: 通知先 / $2: 状態(sent / dry-run / shadow-planned)/ $3: 本文
#
# 「何件通知したか」を後から数えるための台帳。効果測定
# (05-effect-measurement.md)はこのファイルを数えて行う。
# 実際にSlackへ送ったかどうかに関わらず、必ずここに1行残す。
# ---------------------------------------------------------------------
ar_record_outbox() {
    local channel="$1" status="$2" text="$3"
    mkdir -p "$(dirname "$AR_OUTBOX")"
    printf '%s\t%s\t%s\t%s\n' "$(ar_now_str)" "$channel" "$status" "$(ar_sanitize "$text")" >>"$AR_OUTBOX"
}

# ---------------------------------------------------------------------
# Slackへ実際に送信する(下位関数)
#   $1: 通知先ラベル(critical / daily / legacy)
#   $2: 本文
# ---------------------------------------------------------------------
ar_send() {
    local channel="$1" text="$2"
    local webhook payload http_status

    case "$channel" in
        critical) webhook="${AR_WEBHOOK_CRITICAL}" ;;
        daily)    webhook="${AR_WEBHOOK_DAILY}" ;;
        legacy)   webhook="${AR_WEBHOOK_LEGACY}" ;;
        *)
            ar_log ERROR "不明な通知先です: ${channel}"
            return 1
            ;;
    esac

    # AR_ENABLE_SLACK=false のときは送信せずに台帳へ書くだけ(ドライラン)。
    # 検証段階や自動テストでは、本物のSlackを汚さずに件数だけ数えたい。
    if [[ "${AR_ENABLE_SLACK}" != "true" ]]; then
        ar_record_outbox "$channel" "dry-run" "$text"
        return 0
    fi

    # jq -n --arg で本文をJSON文字列として安全にエスケープする。
    # ログ本文には " や改行が含まれるため、文字列連結で自前のJSONを
    # 組み立てると簡単に壊れる(案件No.3と同じ方針)。
    payload="$(jq -n --arg text "$text" '{text: $text}')"

    # curl 自体が失敗した場合(名前解決できない・接続できない等)は
    # HTTPステータスが取れないので、"000" を入れて区別できるようにする。
    if ! http_status="$(curl -sS -o /dev/null -w '%{http_code}' \
        --max-time 10 \
        -X POST \
        -H 'Content-type: application/json' \
        --data "$payload" \
        "$webhook" 2>/dev/null)"; then
        http_status="000"
    fi

    if [[ "$http_status" == "200" ]]; then
        ar_record_outbox "$channel" "sent" "$text"
    else
        # 送信失敗でも処理は止めない。ただし「送れなかった」事実は必ず残す。
        ar_log ERROR "Slack送信に失敗しました(通知先=${channel} HTTP=${http_status})"
        ar_record_outbox "$channel" "failed" "$text"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------
# 通知の送信(上位関数。モードによる制御つき)
#
# AR_MODE=shadow(影実行)のときは、判定はするが新経路への送信はしない。
# 「新旧の判定結果を並行で記録して突き合わせる」段階的移行のための仕組み
# (詳細は 04-build-guide.md のStep 8)。
# 通知先が record(記録のみ)の場合は、そもそも何も送らない。
# ---------------------------------------------------------------------
ar_send_gated() {
    local channel="$1" text="$2"

    if [[ "$channel" == "record" ]]; then
        return 0
    fi

    if [[ "${AR_MODE}" == "active" ]]; then
        ar_send "$channel" "$text"
    else
        ar_record_outbox "$channel" "shadow-planned" "$text"
    fi
    return 0
}

# ---------------------------------------------------------------------
# 全件記録(records.jsonl)への追記
#
# JSON Lines(=1行に1件のJSONを書く形式)で保存する。
# 行単位なので追記が簡単で、jq でそのまま集計できる。
#
# ★この改善のいちばん大事な約束★
#   通知するかどうかに関わらず、受け取った通知は必ずここに全件残す。
#   「通知を減らす」ことと「記録を減らす」ことは全く別である。
# ---------------------------------------------------------------------
ar_append_record() {
    local ts="$1" epoch="$2" source_name="$3" host="$4"
    local rule_id="$5" severity="$6" channel="$7" action="$8"
    local adjust="$9" agg_key="${10}" message="${11}"

    mkdir -p "$(dirname "$AR_RECORD_FILE")"

    # -c は compact(1行に詰めて出力)。JSON Lines にするために必要。
    jq -c -n \
        --arg ts "$ts" \
        --arg epoch "$epoch" \
        --arg date "${ts%% *}" \
        --arg source "$source_name" \
        --arg host "$host" \
        --arg rule_id "$rule_id" \
        --arg severity "$severity" \
        --arg channel "$channel" \
        --arg action "$action" \
        --arg adjust "$adjust" \
        --arg mode "${AR_MODE}" \
        --arg agg_key "$agg_key" \
        --arg message "$message" \
        '{ts:$ts, epoch:($epoch|tonumber), date:$date, source:$source, host:$host,
          rule_id:$rule_id, severity:$severity, channel:$channel, action:$action,
          adjust:$adjust, mode:$mode, agg_key:$agg_key, message:$message}' \
        >>"$AR_RECORD_FILE"
}

# ---------------------------------------------------------------------
# 重複排除(dedup)の判定
#   $1: 集約キー / $2: メッセージ / $3: 現在のエポック秒
#   戻り値: 0=重複(通知しない) / 1=重複ではない(通知する)
#
# 「まったく同じ文面」が短時間(既定180秒)に再送されたときだけ落とす。
# 集約(aggregation)との違い:
#   ・重複排除は「同じものが2回来た」を1回にする(情報量は変わらない)
#   ・集約は「別々のものをまとめて1件にする」(件数の情報を持ち回る)
# P1は集約しない代わりに、この重複排除だけを効かせる。
# 重要な通知を「まとめて遅らせる」ことは絶対にしないという設計。
# ---------------------------------------------------------------------
ar_is_duplicate() {
    local agg_key="$1" message="$2" now="$3"
    local hash state_file last

    hash="$(printf '%s|%s' "$agg_key" "$message" | md5sum | cut -d' ' -f1)"
    state_file="${AR_DATA_DIR}/dedup_${hash}.txt"
    mkdir -p "$AR_DATA_DIR"

    if [[ -f "$state_file" ]]; then
        last="$(cat "$state_file")"
        if [[ "$last" =~ ^(0|[1-9][0-9]*)$ ]] && (( now - last < AR_DEDUP_SECONDS )); then
            printf '%s\n' "$now" >"$state_file"
            return 0
        fi
    fi

    printf '%s\n' "$now" >"$state_file"
    return 1
}

# ---------------------------------------------------------------------
# 復旧通知かどうかの判定
#   $1: ルールID
#
# 「どのルールが復旧通知か」はスクリプトに埋め込まず、設定ファイルの
# AR_RECOVERY_RULES に列挙する。ルールを増やしたときに本体を
# 触らなくて済むようにするため。
# ---------------------------------------------------------------------
ar_is_recovery_rule() {
    local rule_id="$1" candidate
    for candidate in ${AR_RECOVERY_RULES}; do
        [[ "$candidate" == "$rule_id" ]] && return 0
    done
    return 1
}

# ---------------------------------------------------------------------
# 集約ウィンドウへの積み上げ
#   $1: 集約キー / $2: エポック秒 / $3: ルールID / $4: ホスト
#   $5: 重要度 / $6: 通知先 / $7: 1行化済みメッセージ
#
# 状態ファイル(1ウィンドウにつき1ファイル)の書式(タブ区切り):
#   ウィンドウ開始epoch / 件数 / エスカレーション済み(0|1)
#   / 重要度 / 通知先 / ルールID / ホスト / 代表メッセージ
# ---------------------------------------------------------------------
ar_accumulate() {
    local agg_key="$1" epoch="$2" rule_id="$3" host="$4"
    local severity="$5" channel="$6" message="$7"
    local key_safe state_file window
    local ws pending esc sev ch rid hst sample

    key_safe="$(ar_safe_key "$agg_key")"
    state_file="${AR_DATA_DIR}/agg_${key_safe}.tsv"
    window="${AR_RULE_WINDOW[$rule_id]:-$AR_DEFAULT_WINDOW}"
    mkdir -p "$AR_DATA_DIR"

    # 既にウィンドウがあり、かつ期限切れなら先に閉じる(まとめ通知を出す)。
    # cronによる定期flushを待たずにここでも閉じることで、
    # 「古いウィンドウに新しい通知が混ざる」事故を防ぐ。
    if [[ -f "$state_file" ]]; then
        ar_flush_one "$state_file" "$epoch"
    fi

    if [[ -f "$state_file" ]]; then
        IFS=$'\t' read -r ws pending esc sev ch rid hst sample <"$state_file"
    else
        ws="$epoch"
        pending=0
        esc=0
        sev="$severity"
        ch="$channel"
        rid="$rule_id"
        hst="$host"
        sample="$message"
    fi

    pending=$((pending + 1))

    # --- 大量発生時のエスカレーション ---
    # 同じ種類の通知が短時間に大量に出ているときは、たとえ重要度が
    # 低く設定されていても「何か異常なことが起きている」サイン。
    # ウィンドウにつき1回だけ、P1チャンネルへ知らせる。
    # 「重要な通知まで消してしまう」ことへの安全弁のひとつ。
    if (( pending >= AR_ESCALATE_COUNT )) && [[ "$esc" == "0" ]]; then
        esc=1
        ar_send_gated "critical" ":rotating_light: *[エスカレーション] 同一種別の通知が大量発生しています*
ルール: ${rid} ${AR_RULE_DESC[$rid]:-}
ホスト: ${hst}
直近 ${window} 秒で ${pending} 件を超えました(通常時の重要度: ${sev})。
まとめ通知を待たずに先行してお知らせしています。詳細は日次サマリと記録を確認してください。"
        ar_log WARN "大量発生エスカレーション: ${agg_key} が ${pending} 件"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$ws" "$pending" "$esc" "$sev" "$ch" "$rid" "$hst" "$sample" >"$state_file"
}

# ---------------------------------------------------------------------
# 集約ウィンドウを1つ閉じる
#   $1: 状態ファイルのパス / $2: 現在のエポック秒
#
# ウィンドウの期間が過ぎていれば、その間にたまった件数を
# 「まとめ通知」1件として送り、状態ファイルを削除する。
# 通知先が record(P3)の場合は送信しない(記録と日次サマリに任せる)。
# ---------------------------------------------------------------------
ar_flush_one() {
    local state_file="$1" now="$2"
    local ws pending esc sev ch rid hst sample window desc text

    [[ -f "$state_file" ]] || return 0
    IFS=$'\t' read -r ws pending esc sev ch rid hst sample <"$state_file"

    # 状態ファイルが壊れていたら、その場で捨てて作り直させる。
    # 不正な値のまま算術式に渡すとスクリプトが異常終了するため。
    if ! [[ "$ws" =~ ^(0|[1-9][0-9]*)$ ]] || ! [[ "$pending" =~ ^(0|[1-9][0-9]*)$ ]]; then
        ar_log WARN "集約状態ファイルが不正なため初期化します: ${state_file}"
        rm -f "$state_file"
        return 0
    fi

    window="${AR_RULE_WINDOW[$rid]:-$AR_DEFAULT_WINDOW}"
    if (( now - ws < window )); then
        return 0
    fi

    desc="${AR_RULE_DESC[$rid]:-(説明なし)}"

    if [[ "$ch" != "record" ]]; then
        text=":large_blue_circle: *[${sev}] まとめ通知(即時対応は不要)*
ルール: ${rid} ${desc}
ホスト: ${hst}
集約期間: $(ar_epoch_to_str "$ws") 〜 $(ar_epoch_to_str "$((ws + window))")(${window}秒)
件数: ${pending}件(この期間の同種通知をまとめて1件にしています)
代表メッセージ: ${sample}
全件は日次サマリと記録(records.jsonl)から確認できます。"
        ar_send_gated "$ch" "$text"
        ar_log INFO "まとめ通知を送出: ${rid}/${hst} ${pending}件 (エスカレーション済み=${esc})"
    else
        ar_log INFO "記録のみのため通知は送りません: ${rid}/${hst} ${pending}件 (エスカレーション済み=${esc})"
    fi

    rm -f "$state_file"
    return 0
}

# ---------------------------------------------------------------------
# 期限切れの集約ウィンドウをすべて閉じる
#   $1: 現在のエポック秒
#
# 本番運用では cron から alert-flush.sh 経由で5分ごとに呼ばれる。
# ---------------------------------------------------------------------
ar_flush_expired() {
    local now="$1"
    local state_file

    [[ -d "$AR_DATA_DIR" ]] || return 0
    for state_file in "${AR_DATA_DIR}"/agg_*.tsv; do
        # マッチするファイルが1つも無いとき、Bashはパターン文字列
        # そのものをループ変数に入れてしまう。実在チェックで空振りを弾く。
        [[ -e "$state_file" ]] || continue
        ar_flush_one "$state_file" "$now"
    done
    return 0
}

# ---------------------------------------------------------------------
# 通知1件を処理する(この改善ツールの中心となる関数)
#   $1: 発生日時("YYYY-MM-DD HH:MM:SS")
#   $2: 発生日時のエポック秒
#   $3: 発生元(log-watch / health-check / backup など)
#   $4: 対象ホスト
#   $5: 通知本文(複数行可)
#
# 処理の順番:
#   1. 1行化 → 2. ルールで分類 → 3. 補正(復旧通知の格上げ)
#   → 4. 重要度ごとの振り分け → 5. 影実行なら旧経路へ転送
#   → 6. 全件記録
# ---------------------------------------------------------------------
ar_handle_event() {
    local ts="$1" epoch="$2" source_name="$3" host="$4" raw_message="$5"
    local message classified rule_id severity channel window
    local adjust action agg_key host_key p1_state last_p1

    message="$(ar_sanitize "$raw_message")"

    # --- 2. ルールで分類 ---
    classified="$(ar_classify "$message")"
    IFS=$'\t' read -r rule_id severity channel window <<<"$classified"
    adjust="none"

    # --- 3. 補正: 復旧通知のエスカレーション ---
    # 復旧通知そのものは、単体では対応不要なのでP3(記録のみ)にしている。
    # ただし「直前にP1として通知した障害」の復旧だけは話が別で、
    # 対応中の担当者にとって最も重要な情報になる。そこで、そのホストが
    # P1発報中である場合に限りP1へ格上げする。
    # パターンマッチだけでは決められない「状態に依存する判定」の例。
    host_key="$(ar_safe_key "$host")"
    p1_state="${AR_DATA_DIR}/p1active_${host_key}.txt"
    mkdir -p "$AR_DATA_DIR"

    if ar_is_recovery_rule "$rule_id" && [[ -f "$p1_state" ]]; then
        last_p1="$(cat "$p1_state")"
        if [[ "$last_p1" =~ ^(0|[1-9][0-9]*)$ ]] && (( epoch - last_p1 < AR_P1_ACTIVE_TTL )); then
            severity="P1"
            channel="critical"
            adjust="recovery-escalated"
        fi
        rm -f "$p1_state"
    fi

    agg_key="${rule_id}:${host}"

    # --- 4. 重要度ごとの振り分け ---
    case "$severity" in
        P1)
            # P1は絶対に遅らせない・まとめない。まったく同じ文面の
            # 短時間の再送だけを重複排除で落とす。
            if ar_is_duplicate "$agg_key" "$message" "$epoch"; then
                action="deduped"
            else
                action="notified"
                ar_send_gated "$channel" ":rotating_light: *[P1] 即時対応* ${AR_MENTION_P1}
ルール: ${rule_id} ${AR_RULE_DESC[$rule_id]:-未分類(ルールに一致しなかったため安全側でP1にしています)}
ホスト: ${host} / 発生元: ${source_name}
検知時刻: ${ts}
内容: ${message}"
                # 復旧通知の格上げ判定に使う「P1発報中」の印を残す。
                # ただし復旧通知自体でP1になった場合は印を付け直さない。
                if [[ "$adjust" != "recovery-escalated" ]]; then
                    printf '%s\n' "$epoch" >"$p1_state"
                fi
            fi
            ;;
        P2)
            # P2は翌営業日対応でよい種類なので、即時には送らず
            # 集約ウィンドウにためて、あとでまとめて1件送る。
            action="aggregated"
            ar_accumulate "$agg_key" "$epoch" "$rule_id" "$host" "$severity" "$channel" "$message"
            ;;
        P3)
            # P3は即時通知しない。記録と日次サマリだけに残す。
            # 「捨てている」のではなく「届け方を変えている」点が重要。
            action="recorded"
            # 通知は送らないが、件数だけは集約ウィンドウで数えておく。
            # P3に落とした種別が急に大量発生した場合に、上の
            # 大量発生エスカレーションで気づけるようにするため。
            ar_accumulate "$agg_key" "$epoch" "$rule_id" "$host" "$severity" "$channel" "$message"
            ;;
        *)
            ar_log ERROR "想定外の重要度です: ${severity}(ルール ${rule_id})"
            action="error"
            ;;
    esac

    # --- 5. 影実行(shadow)なら、従来どおり全件を旧チャンネルへ流す ---
    # 判定結果は記録するが、現場の見え方は今までと1ミリも変えない。
    # これにより「新方式に切り替えたら何件になるか」を、
    # 本番の通知を止めるリスクゼロで先に測れる。
    if [[ "${AR_MODE}" != "active" ]]; then
        ar_send "legacy" "$raw_message"
    fi

    # --- 6. 全件記録(通知したかどうかに関わらず必ず残す) ---
    ar_append_record "$ts" "$epoch" "$source_name" "$host" \
        "$rule_id" "$severity" "$channel" "$action" "$adjust" "$agg_key" "$message"

    return 0
}
