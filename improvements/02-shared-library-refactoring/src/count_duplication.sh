#!/usr/bin/env bash
#
# =====================================================================
# count_duplication.sh
# 改善案件No.2: 重複コードの行数を「誰が数えても同じ値になる形」で数える
#
# 目的:
#   改善レポート(05-effect-measurement.md)に載せる「重複していた処理の
#   行数」を、手作業の目分量ではなくコマンドで再現できるようにする。
#   数値の裏付けが取れないと「本当に効果があったのか」を説明できないため。
#
# 数え方のルール(このスクリプトが実装しているルール):
#   1. 対象は projects/ 配下の既存4スクリプトのうち、
#      「ログ出力」「Slack通知」「設定読み込み」「前提コマンドチェック」
#      の4カテゴリに該当する関数定義ブロックとその呼び出し準備コード。
#   2. ブロックの開始行〜終了行(空行を含む)を数える。
#   3. ただし、行頭(先頭の空白を除く)が "#" で始まる行
#      (=コメントだけの行)は数えない。コメントは処理の実体ではないため。
#
# 使い方(リポジトリのルートで実行する):
#   ./improvements/02-shared-library-refactoring/src/count_duplication.sh
# =====================================================================

set -uo pipefail

# REPO_ROOT: このスクリプトの2階層上(= improvements/02-.../src の2つ上)ではなく、
# リポジトリのルートを指す。src -> 案件ディレクトリ -> improvements -> ルート の4階層上。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# 数える対象のブロック定義
#   書式: "カテゴリ|ファイルパス(リポジトリルートからの相対)|開始行|終了行|説明"
BLOCKS=(
  "ログ出力|projects/01-user-account-automation/src/create_users.sh|161|168|log() 関数"
  "設定読み込み|projects/02-backup-automation/src/backup.sh|32|41|設定ファイルの存在確認とsource"
  "ログ出力|projects/02-backup-automation/src/backup.sh|50|57|log() 関数"
  "Slack通知|projects/02-backup-automation/src/backup.sh|62|72|notify_slack() 関数"
  "ログ出力|projects/03-log-monitoring-alert/src/log-watch-alert.sh|48|50|log_info/log_warn/log_error"
  "前提コマンドチェック|projects/03-log-monitoring-alert/src/log-watch-alert.sh|59|68|require_command() 関数と呼び出し4行"
  "Slack通知|projects/03-log-monitoring-alert/src/log-watch-alert.sh|92|137|send_slack_notification() 関数"
  "設定読み込み|projects/04-server-health-check/src/health_check.sh|39|53|設定ファイルの存在確認とsource"
  "ログ出力|projects/04-server-health-check/src/health_check.sh|62|69|log() 関数"
  "Slack通知|projects/04-server-health-check/src/health_check.sh|73|83|notify_slack() 関数"
)

# count_block: 指定ファイルの指定行範囲から、コメントのみの行を除いた行数を数える
#   引数1: ファイルパス / 引数2: 開始行 / 引数3: 終了行
#   標準出力: 行数
count_block() {
  local file="$1" from="$2" to="$3"
  # sed -n "${from},${to}p" で指定範囲だけを取り出し、
  # grep -c -v で「行頭が # の行」以外を数える。
  # grep は1件も一致しないと終了コード1を返すため、|| true で止まらないようにする。
  sed -n "${from},${to}p" "$file" | grep -cvE '^[[:space:]]*#' || true
}

# 出力はMarkdownの表形式にする。日本語(全角文字)はスペースによる桁揃えが
# 崩れやすいため、"|" 区切りにして、そのままドキュメントへ貼れる形にしている。
total=0
echo "| カテゴリ | ファイル | 行範囲 | 行数 |"
echo "|---|---|---|---|"

for block in "${BLOCKS[@]}"; do
  IFS='|' read -r category file from to _desc <<< "$block"
  path="${REPO_ROOT}/${file}"

  if [[ ! -f "$path" ]]; then
    echo "| ${category} | ${file} | - | ファイルが見つかりません |"
    continue
  fi

  lines="$(count_block "$path" "$from" "$to")"
  total=$(( total + lines ))
  echo "| ${category} | ${file} | ${from}-${to} | ${lines} |"
done

# ファイル数もあわせて表示する(「同種の修正で何ファイル触るか」の根拠)
file_count="$(printf '%s\n' "${BLOCKS[@]}" | cut -d'|' -f2 | sort -u | wc -l)"

echo ""
echo "合計(コメントのみの行を除く実コード行数): ${total} 行"
echo "重複が散在しているファイル数            : ${file_count} ファイル"
