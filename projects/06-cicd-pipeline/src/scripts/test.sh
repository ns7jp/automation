#!/usr/bin/env bash
#
# ============================================================
# test.sh
# 案件No.6: CI/CD自動デプロイパイプライン - サンプルアプリの簡易テスト
#
# 概要:
#   GitHub Actionsのtestジョブ(CI)から呼び出される、サンプルアプリ
#   (app/配下の静的サイト)に対する簡易テストスクリプト。
#   pytestやnpm testのような外部のテストフレームワークを使わず、
#   シェルスクリプトとgrep/wcだけで「最低限これが崩れていたら
#   デプロイを止める」というチェックを行う。
#
#   実務では、Webアプリの種類に応じてより高度な自動テスト
#   (単体テスト・結合テスト等)に置き換わっていく部分だが、
#   「テストが自動実行され、失敗したらデプロイされない」という
#   CI/CDパイプラインの骨格そのものは、このシンプルな実装でも
#   体験できる。
#
# 実行方法:
#   bash scripts/test.sh
#   (通常はGitHub Actionsのワークフローから自動実行される)
#
# 終了コード:
#   0 : すべてのテストに合格
#   1 : いずれか1つ以上のテストに失敗
# ============================================================

set -eu
# -e: 各テスト自体の判定はif文の中で行うため、-eによって
#     途中で予期せず止まることは基本的に無いが、想定外のコマンド失敗
#     (例: grep自体が存在しない等)は即座に検知できるようにしておく。
# -u: 未定義の変数を参照した場合にエラーにする(タイプミスの早期発見)。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "${SCRIPT_DIR}/../app" && pwd)"
INDEX_HTML="${APP_DIR}/index.html"

FAIL=0
# FAIL: 1つでもテストに失敗したら1にする、全体の合否フラグ。
# 1件失敗しても残りのテストを最後まで実行し、まとめて結果を
# 報告したいので、途中でexitはせずこのフラグで管理する。

echo "=== [1/3] 必須ファイルの存在チェック ==="
for f in "index.html" "css/style.css"; do
  if [ -f "${APP_DIR}/${f}" ]; then
    echo "OK: ${f} が存在します"
  else
    echo "NG: ${f} が見つかりません" >&2
    FAIL=1
  fi
done

echo "=== [2/3] index.htmlの基本構造チェック ==="
if [ -f "$INDEX_HTML" ] \
   && grep -qi "<!DOCTYPE html>" "$INDEX_HTML" \
   && grep -qi "<html" "$INDEX_HTML" \
   && grep -qi "</html>" "$INDEX_HTML"; then
  echo "OK: DOCTYPE宣言と<html>〜</html>タグの対応が確認できました"
else
  echo "NG: index.htmlの基本構造(DOCTYPE/htmlタグ)が壊れています" >&2
  FAIL=1
fi

echo "=== [3/3] <div>タグの開始/終了タグ数の一致チェック ==="
if [ -f "$INDEX_HTML" ]; then
  OPEN_COUNT="$(grep -o "<div" "$INDEX_HTML" | wc -l)"
  CLOSE_COUNT="$(grep -o "</div>" "$INDEX_HTML" | wc -l)"
  if [ "$OPEN_COUNT" -eq "$CLOSE_COUNT" ]; then
    echo "OK: <div>の開始タグ(${OPEN_COUNT}個)と終了タグ(${CLOSE_COUNT}個)が一致しています"
  else
    echo "NG: <div>タグの数が一致しません(開始${OPEN_COUNT}個 / 終了${CLOSE_COUNT}個)" >&2
    FAIL=1
  fi
else
  echo "NG: index.htmlが見つからないため、タグ数チェックをスキップします" >&2
  FAIL=1
fi

echo "------------------------------------------------------------"
if [ "$FAIL" -eq 0 ]; then
  echo "=== すべてのテストに合格しました ==="
  exit 0
else
  echo "=== テストに失敗した項目があります(上記のNGを参照) ===" >&2
  exit 1
fi
