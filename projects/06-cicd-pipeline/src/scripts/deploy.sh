#!/usr/bin/env bash
#
# ============================================================
# deploy.sh
# 案件No.6: CI/CD自動デプロイパイプライン - デプロイ本体スクリプト
#
# 概要:
#   app/ 配下のファイルを rsync(SSH経由)でデプロイ先サーバーへ
#   反映する。GitHub Actionsのdeployジョブは、GitHub Secretsから
#   読み込んだ接続情報を環境変数として渡した上で、このスクリプトを
#   そのまま実行している(.github/workflows/deploy.yml参照)。
#
#   ワークフロー経由だけでなく、手元やサーバー上から同じデプロイ処理を
#   手動で再現・検証したい場合にも、このスクリプト単体で実行できる。
#   「CIの中でしか動かない特別な処理」をできるだけ作らないことで、
#   トラブル発生時に人間が手動で同じ手順を再現しやすくしている。
#
# 実行方法(手動実行の例):
#   DEPLOY_HOST=192.168.1.30 \
#   DEPLOY_USER=deploy \
#   DEPLOY_PORT=22 \
#   DEPLOY_PATH=/var/www/sample-app \
#   DEPLOY_SSH_KEY=~/.ssh/id_ed25519_deploy \
#     bash scripts/deploy.sh
#
# 注意:
#   本番のGitHub Actionsワークフロー上では、これらの値はすべて
#   GitHub Secretsとして管理され、コード中に直接書かれることはない
#   (なぜSecretsを使うのかはREADME.md/02-design.mdを参照)。
# ============================================================

set -eu
# -e: rsyncやsshが1つでも失敗したら、その時点でスクリプトを止める。
#     デプロイ処理は「途中まで反映されて終わる」状態が一番困るため、
#     失敗したら即座に中断し、呼び出し元(GitHub Actions)にも
#     失敗(終了コード0以外)として伝える。
# -u: 未定義の環境変数を参照した場合にエラーにする(設定漏れの早期発見)。

# ---- 必須の環境変数チェック ----
# ":" は「何もしない」というbashの組み込みコマンド。
# "${VAR:?message}" は、VARが未設定または空文字の場合にmessageを
# 標準エラー出力へ表示してスクリプトを終了させる、という
# 「必須パラメータの入力チェック」でよく使われる書き方。
: "${DEPLOY_HOST:?環境変数 DEPLOY_HOST が未設定です(接続先ホスト名/IP)}"
: "${DEPLOY_USER:?環境変数 DEPLOY_USER が未設定です(SSH接続ユーザー名)}"
: "${DEPLOY_PATH:?環境変数 DEPLOY_PATH が未設定です(サーバー上の配置先ディレクトリ)}"
: "${DEPLOY_SSH_KEY:?環境変数 DEPLOY_SSH_KEY が未設定です(秘密鍵ファイルのパス)}"
: "${DEPLOY_PORT:=22}"
# DEPLOY_PORTだけは「未設定なら22番ポートを既定値とする」という
# 意味の書き方(:=)にしている。他の4つは省略を許さず、必ずエラーにする。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${SCRIPT_DIR}/app"

echo "[INFO] デプロイ元ディレクトリ: ${APP_DIR}"
echo "[INFO] デプロイ先        : ${DEPLOY_USER}@${DEPLOY_HOST}:${DEPLOY_PATH} (port ${DEPLOY_PORT})"

echo "[INFO] デプロイ情報(コミットハッシュ・日時)をdeploy-info.txtに書き込みます"
DEPLOYED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
# git rev-parseが失敗しても(gitリポジトリでない場所から手動実行した場合等)
# デプロイ処理自体は止めたくないので、失敗時は"unknown"を使う。
GIT_COMMIT="$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
{
  echo "deployed_at=${DEPLOYED_AT}"
  echo "git_commit=${GIT_COMMIT}"
} > "${APP_DIR}/deploy-info.txt"

echo "[INFO] rsyncでファイルを転送します"
# -a               : ディレクトリ構造・権限・タイムスタンプなどをできるだけ
#                     保ったまま同期する(archiveモード)
# -v               : 転送したファイル名を表示する(verbose)
# -z               : 転送時にデータを圧縮する
# --delete         : 転送元(app/)に無いファイルは転送先からも削除する
#                     (「消したはずのファイルが本番に残り続ける」事故を防ぐ)
# -e "ssh ..."     : rsyncが内部で使うSSH接続コマンドを、鍵ファイルと
#                     ポート番号を指定した上で明示する
# StrictHostKeyChecking=accept-new
#                   : 初回接続時のホスト鍵を自動的に信頼してknown_hostsに
#                     追加する設定。CI環境のように対話的にyes/noを
#                     入力できない場面向け(トレードオフは
#                     05-troubleshooting.mdで解説)
rsync -avz --delete \
  -e "ssh -i ${DEPLOY_SSH_KEY} -p ${DEPLOY_PORT} -o StrictHostKeyChecking=accept-new" \
  "${APP_DIR}/" \
  "${DEPLOY_USER}@${DEPLOY_HOST}:${DEPLOY_PATH}/"

echo "[INFO] デプロイが完了しました(commit: ${GIT_COMMIT})"
