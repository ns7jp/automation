#!/usr/bin/env bash
# ============================================================
# verify.sh
#
# Ansibleで構築したWebサーバーが、要求仕様(01-requirements.md)を
# 満たしているかをまとめて確認するための検証スクリプト。
# 対象サーバー上で実行する前提で書かれている。
#
# 実行方法1: コントロールノードから、Ansibleのscriptモジュールで
#            スクリプトを転送しつつ実行する(Ansibleのad-hocコマンド)
#   ansible webservers -m ansible.builtin.script -a "verify.sh" --become
#
# 実行方法2: 対象サーバーに直接ログインして実行する
#   sudo bash verify.sh
# ============================================================

set -uo pipefail
# 注: set -e は使わない。1つのチェックが失敗しても最後まで全項目を確認し、
# まとめて結果を見たいため(1つエラーが出た時点で止まってしまうと不便)。

pass=0
fail=0

# 1件分のチェック結果を記録・表示する関数
# 引数1: チェック内容のラベル
# 引数2: "OK" ならPASS、それ以外の文字列はFAIL扱いにしてそのまま表示する
check() {
  local label="$1"
  local result="$2"
  if [[ "$result" == "OK" ]]; then
    echo "[PASS] ${label}"
    pass=$((pass + 1))
  else
    echo "[FAIL] ${label} (詳細: ${result})"
    fail=$((fail + 1))
  fi
}

echo "=== 1. Nginxサービスが稼働しているか ==="
if systemctl is-active --quiet nginx; then
  check "nginxサービスがactiveである" "OK"
else
  check "nginxサービスがactiveである" "$(systemctl is-active nginx 2>&1 || true)"
fi

echo "=== 2. ポート80で静的ページが取得できるか ==="
http_code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost/ || echo "000")
if [[ "$http_code" == "200" ]]; then
  check "http://localhost/ が200を返す" "OK"
else
  check "http://localhost/ が200を返す" "HTTPステータス ${http_code}"
fi

echo "=== 3. タイムゾーンがAsia/Tokyoに設定されているか ==="
tz=$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "unknown")
check "タイムゾーンがAsia/Tokyoである" "$([[ "$tz" == "Asia/Tokyo" ]] && echo OK || echo "$tz")"

echo "=== 4. SSHのパスワード認証が無効化されているか ==="
if grep -Eq '^PasswordAuthentication[[:space:]]+no' /etc/ssh/sshd_config; then
  check "sshd_configでPasswordAuthentication noになっている" "OK"
else
  check "sshd_configでPasswordAuthentication noになっている" "NG(no以外の設定、または未設定)"
fi

echo "=== 5. rootの直接SSHログインが無効化されているか ==="
if grep -Eq '^PermitRootLogin[[:space:]]+no' /etc/ssh/sshd_config; then
  check "sshd_configでPermitRootLogin noになっている" "OK"
else
  check "sshd_configでPermitRootLogin noになっている" "NG(no以外の設定、または未設定)"
fi

echo "=== 6. ファイアウォールが有効で、許可設定が入っているか ==="
if command -v ufw >/dev/null 2>&1; then
  ufw_status_line=$(ufw status | head -n1)
  echo "  ufw status: ${ufw_status_line}"
  check "ufwが有効化されている(Status: active)" "$([[ "$ufw_status_line" == "Status: active" ]] && echo OK || echo "$ufw_status_line")"
elif command -v firewall-cmd >/dev/null 2>&1; then
  if firewall-cmd --state 2>/dev/null | grep -q running; then
    check "firewalldが有効化されている" "OK"
  else
    check "firewalldが有効化されている" "NG"
  fi
else
  check "ファイアウォールツールの検出" "ufw/firewalldのどちらも見つかりません"
fi

echo
echo "=== 結果サマリ ==="
echo "PASS: ${pass}  FAIL: ${fail}"

if [[ "$fail" -gt 0 ]]; then
  echo "一部のチェックに失敗しています。上記の [FAIL] 項目を確認してください。"
  exit 1
fi

echo "すべてのチェックに合格しました。"
exit 0
