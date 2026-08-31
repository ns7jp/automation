#!/usr/bin/env bash
#
# install.sh
# ---------------------------------------------------------------------------
# 目的:
#   log-watch-alert を systemd サービスとして一括インストールする補助
#   スクリプト。学習目的では 03-build-guide.md の手順を1ステップずつ手で
#   実行することを推奨するが、2回目以降の環境構築や「自動化された構築」
#   のデモとして使えるようまとめたもの。
#
# 使い方:
#   sudo ./install.sh
#
# 前提: このスクリプトと同じディレクトリに、以下のファイルが存在すること
#   - log-watch-alert.sh
#   - log-watch-alert.env.example
#   - log-watch-alert.service
# ---------------------------------------------------------------------------

set -euo pipefail

INSTALL_DIR="/opt/log-watch-alert"
STATE_DIR="/var/lib/log-watch-alert"
SERVICE_USER="logwatch"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "root権限が必要です。'sudo ./install.sh' のように実行してください。" >&2
  exit 1
fi

echo "==> 1/6 サービス専用ユーザーを作成します: ${SERVICE_USER}"
# 既に存在する場合は作成をスキップする(2回目以降の実行でもエラーにしない)
if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
  echo "  -> ユーザー '${SERVICE_USER}' を作成しました"
else
  echo "  -> ユーザー '${SERVICE_USER}' は既に存在します(スキップ)"
fi

echo "==> 2/6 インストール先ディレクトリを準備します: ${INSTALL_DIR}"
mkdir -p "$INSTALL_DIR"
install -m 750 "${SCRIPT_DIR}/log-watch-alert.sh" "${INSTALL_DIR}/log-watch-alert.sh"

echo "==> 3/6 設定ファイル(.env)を準備します"
if [[ ! -f "${INSTALL_DIR}/.env" ]]; then
  install -m 600 "${SCRIPT_DIR}/log-watch-alert.env.example" "${INSTALL_DIR}/.env"
  echo "  -> ${INSTALL_DIR}/.env を作成しました。SLACK_WEBHOOK_URL 等を編集してください。"
else
  echo "  -> ${INSTALL_DIR}/.env は既に存在するため上書きしません"
fi

echo "==> 4/6 状態ファイル用ディレクトリを作成します: ${STATE_DIR}"
mkdir -p "$STATE_DIR"
chown -R "${SERVICE_USER}:${SERVICE_USER}" "$STATE_DIR" "$INSTALL_DIR"

echo "==> 5/6 systemdユニットファイルを配置します"
install -m 644 "${SCRIPT_DIR}/log-watch-alert.service" /etc/systemd/system/log-watch-alert.service

echo "==> 6/6 systemdに変更を認識させ、自動起動を有効化します"
systemctl daemon-reload
systemctl enable log-watch-alert.service

cat <<'EOS'

インストールが完了しました。次の手順を行ってください。
  1. /opt/log-watch-alert/.env を編集し、SLACK_WEBHOOK_URL などを設定する
  2. 監視対象のログファイル(LOG_FILEに指定したパス)が存在することを確認する
  3. sudo systemctl start log-watch-alert
  4. sudo systemctl status log-watch-alert で起動確認する

詳細は 03-build-guide.md を参照。
EOS
