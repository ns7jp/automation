#!/usr/bin/env bash
#
# =====================================================================
# md2html.sh
# 改善案件No.1: 月次運用報告書の自動生成 - Markdown→HTML変換スクリプト
#
# 目的:
#   ops_report.sh が生成したMarkdownレポートを、ブラウザでそのまま
#   開けるHTMLに変換する。
#   「Markdownが読めない人にもメールで送りたい」という要望に応えるための
#   おまけ機能であり、ops_report.conf の ENABLE_HTML_REPORT=true の
#   ときだけ呼び出される。
#
# 実行方法:
#   ./md2html.sh 入力.md 出力.html
#
# 【対応範囲についての正直な注意】
#   これは汎用のMarkdown変換ツールではない。
#   ops_report.sh が出力する範囲の記法(見出し / 表 / 箇条書き /
#   引用 / コードブロック / 強調 / インラインコード / HTMLコメント)
#   だけに対応した、用途を絞った簡易コンバーターである。
#   汎用の変換が必要なら pandoc の導入を検討すること。
# =====================================================================

set -u

INPUT="${1:-}"
OUTPUT="${2:-}"

if [ -z "$INPUT" ] || [ -z "$OUTPUT" ]; then
    echo "使い方: md2html.sh 入力.md 出力.html" >&2
    exit 1
fi

if [ ! -f "$INPUT" ]; then
    echo "[ERROR] 入力ファイルが見つかりません: ${INPUT}" >&2
    exit 1
fi

TITLE="$(basename "$INPUT" .md)"

# ----------------------------------------------------------------
# HTMLのヘッダー部分(スタイル定義)
# ----------------------------------------------------------------
# <<'HTML_HEAD' のようにEOFワードを ' ' で囲むと、
# 中の $ や ` がシェルに解釈されず「書いたそのまま」出力される。
# CSSには { } や記号が多いので、この書き方が安全。
cat > "$OUTPUT" <<HTML_HEAD
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<title>${TITLE}</title>
<style>
  body { font-family: "Hiragino Sans", "Yu Gothic", Meiryo, sans-serif;
         line-height: 1.7; max-width: 960px; margin: 2em auto; padding: 0 1em; color: #222; }
  h1 { border-bottom: 3px solid #2c6faf; padding-bottom: 0.3em; }
  h2 { border-left: 6px solid #2c6faf; padding-left: 0.5em; margin-top: 2em; }
  table { border-collapse: collapse; width: 100%; margin: 1em 0; }
  th, td { border: 1px solid #ccc; padding: 0.4em 0.7em; text-align: left; }
  th { background: #eef4fa; }
  tr:nth-child(even) td { background: #fafafa; }
  code { background: #f2f2f2; padding: 0.1em 0.35em; border-radius: 3px; }
  pre { background: #f6f6f6; border: 1px solid #ddd; padding: 0.8em; overflow-x: auto; }
  blockquote { border-left: 4px solid #bbb; margin: 1em 0; padding: 0.2em 1em; color: #555; background: #fbfbfb; }
  hr { border: 0; border-top: 1px solid #ddd; margin: 2em 0; }
</style>
</head>
<body>
HTML_HEAD

# ----------------------------------------------------------------
# 本文の変換(awkで1行ずつ処理する)
# ----------------------------------------------------------------
# awkは「1行読む → ルールに当てはめる → 出力する」を繰り返す道具。
# Markdownのように「行の先頭の記号で意味が決まる」形式との相性が良い。
awk '
# --- 文字参照のエスケープ(HTMLとして誤解釈されないようにする) ---
function esc(s) {
    gsub(/&/, "\\&amp;", s)
    gsub(/</, "\\&lt;",  s)
    gsub(/>/, "\\&gt;",  s)
    return s
}

# --- 行内の装飾(**強調** と `コード`)をHTMLタグに置き換える ---
function inline(s) {
    # `コード` → <code>コード</code>
    while (match(s, /`[^`]+`/)) {
        body = substr(s, RSTART + 1, RLENGTH - 2)
        s = substr(s, 1, RSTART - 1) "<code>" body "</code>" substr(s, RSTART + RLENGTH)
    }
    # **強調** → <strong>強調</strong>
    while (match(s, /\*\*[^*]+\*\*/)) {
        body = substr(s, RSTART + 2, RLENGTH - 4)
        s = substr(s, 1, RSTART - 1) "<strong>" body "</strong>" substr(s, RSTART + RLENGTH)
    }
    return s
}

# 表・箇条書き・引用は「複数行でひとかたまり」になるため、
# 別の種類の行が来た時点で閉じタグを出す必要がある。その後始末をする関数。
function close_blocks() {
    if (in_table) { print "</tbody></table>"; in_table = 0 }
    if (in_list)  { print "</ul>";            in_list  = 0 }
    if (in_quote) { print "</blockquote>";    in_quote = 0 }
}

BEGIN { in_table = 0; in_list = 0; in_quote = 0; in_code = 0 }

# --- コードブロック( ``` で囲まれた範囲)---
/^```/ {
    if (in_code) { print "</pre>"; in_code = 0 }
    else         { close_blocks(); print "<pre>"; in_code = 1 }
    next
}
in_code { print esc($0); next }

# --- HTMLコメント(<!-- --> )はそのまま通す ---
/^<!--/ { close_blocks(); print; next }
/-->$/  { print; next }

# --- 水平線 ---
/^---[-]*$/ { close_blocks(); print "<hr>"; next }

# --- 見出し ---
/^## /  { close_blocks(); print "<h2>" inline(esc(substr($0, 4))) "</h2>"; next }
/^# /   { close_blocks(); print "<h1>" inline(esc(substr($0, 3))) "</h1>"; next }

# --- 表の区切り行( |---|---| )は読み飛ばし、ヘッダー行を閉じる ---
/^\|[ :|-]+\|$/ && in_table == 1 { print "</thead><tbody>"; in_table = 2; next }

# --- 表の行 ---
/^\|/ {
    if (in_list)  { print "</ul>";         in_list  = 0 }
    if (in_quote) { print "</blockquote>"; in_quote = 0 }

    line = $0
    sub(/^\|/, "", line)     # 先頭の | を削る
    sub(/\|$/, "", line)     # 末尾の | を削る
    n = split(line, cells, "|")

    if (in_table == 0) { print "<table><thead>"; in_table = 1; tag = "th" }
    else               { tag = "td" }

    printf "<tr>"
    for (i = 1; i <= n; i++) {
        c = cells[i]
        gsub(/^ +| +$/, "", c)            # 前後の空白を削る
        printf "<%s>%s</%s>", tag, inline(esc(c)), tag
    }
    print "</tr>"
    next
}

# --- 引用( > で始まる行)---
/^> / {
    if (in_table) { print "</tbody></table>"; in_table = 0 }
    if (in_list)  { print "</ul>";            in_list  = 0 }
    if (!in_quote) { print "<blockquote>"; in_quote = 1 }
    print "<p>" inline(esc(substr($0, 3))) "</p>"
    next
}

# --- 箇条書き( - で始まる行)---
/^- / {
    if (in_table) { print "</tbody></table>"; in_table = 0 }
    if (in_quote) { print "</blockquote>";    in_quote = 0 }
    if (!in_list) { print "<ul>"; in_list = 1 }
    print "<li>" inline(esc(substr($0, 3))) "</li>"
    next
}

# --- 空行 = ブロックの終わり ---
/^[[:space:]]*$/ { close_blocks(); next }

# --- それ以外はふつうの段落 ---
{ close_blocks(); print "<p>" inline(esc($0)) "</p>" }

END { close_blocks(); if (in_code) print "</pre>" }
' "$INPUT" >> "$OUTPUT"

# ----------------------------------------------------------------
# HTMLのフッター
# ----------------------------------------------------------------
cat >> "$OUTPUT" <<'HTML_FOOT'
</body>
</html>
HTML_FOOT

exit 0
