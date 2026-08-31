# 03. 構築手順書

本手順は、Ubuntu Server 22.04 LTS上で1から環境を構築する想定で進める。コマンドは基本的に`sudo`権限で実行する(実行例では省略している箇所がある)。

実際の現場では監視対象サーバーが複数台(3〜5台)存在する前提だが、この手順書では検証用のVMが1台しか無くても最後まで動作確認できるよう、**Step 5で「自ホスト(localhost)だけで完結する検証用の設定」に一時的に切り替え**、Step 12で実運用を想定した内容に戻す、という進め方にしている。

## Step 0. 前提の確認

```bash
lsb_release -a
```

```text
Distributor ID: Ubuntu
Description:    Ubuntu 22.04.4 LTS
Release:        22.04
Codename:       jammy
```

必要なコマンドが揃っているかも確認しておく。

```bash
which ping curl awk date python3
```

```text
/usr/bin/ping
/usr/bin/curl
/usr/bin/awk
/usr/bin/date
/usr/bin/python3
```

**何をしているか**: 検証環境([01-requirements.md](./01-requirements.md)参照)とズレがないか、また本ツールが依存するコマンドが最初から揃っているかを確認している。

💡ポイント: `ping`だけはディストリビューションによってはネットワークツール一式(`iputils-ping`)が別パッケージになっていることがある。`which ping`で何も表示されない場合は`sudo apt install -y iputils-ping`でインストールする。

## Step 1. 配置先ディレクトリの作成

```bash
sudo mkdir -p /opt/server-health-check/report
sudo mkdir -p /var/lib/server-health-check
sudo mkdir -p /var/log/server-health-check
```

**何をしているか**: スクリプト本体・レポート出力先・状態ファイル置き場・ログ置き場の4つのディレクトリを作成している。`-p`オプションにより、親ディレクトリが無くても一括作成でき、既に存在していてもエラーにならない。

**なぜ**: 「スクリプトと設定」「状態(揮発性が高い)」「ログ・履歴(蓄積していくデータ)」を別ディレクトリに分けておくことで、それぞれに適切な権限やバックアップ方針を設定しやすくなる([02-design.md](./02-design.md) 3章参照)。

## Step 2. スクリプト・設定ファイルの配置

本リポジトリの`src/`配下のファイルを対象サーバーへ配置する。

```bash
sudo cp src/health_check.sh /opt/server-health-check/health_check.sh
sudo cp src/health_check.conf /opt/server-health-check/health_check.conf
sudo cp src/targets.conf /opt/server-health-check/targets.conf
```

**確認**:

```bash
ls -l /opt/server-health-check/
```

```text
-rw-r--r-- 1 root root 2158 Aug 31 09:00 health_check.conf
-rwxr-xr-x 1 root root 9840 Aug 31 09:00 health_check.sh
-rw-r--r-- 1 root root 1580 Aug 31 09:00 targets.conf
drwxr-xr-x 2 root root 4096 Aug 31 09:00 report
```

## Step 3. 実行権限・アクセス権限の設定

```bash
sudo chmod 755 /opt/server-health-check/health_check.sh
sudo chmod 600 /opt/server-health-check/health_check.conf
sudo chmod 644 /opt/server-health-check/targets.conf
```

**何をしているか**:
- `health_check.sh`に実行権限(`x`)を付与し、直接実行できるようにする
- `health_check.conf`はSlack WebhookのURL(秘匿情報)を含むため、所有者(root)以外は読めないよう`600`(所有者のみ読み書き可)に制限する
- `targets.conf`は秘匿情報を含まないため、閲覧はしやすいが書き込みは所有者のみという`644`にしている

💡ポイント: `chmod 600`を忘れると、サーバーの他の利用者からWebhook URLが読めてしまう。パーミッションは「動けばOK」ではなく、セキュリティの観点でも必ずセットで確認する([01-requirements.md](./01-requirements.md) NFR-03)。

**確認**:

```bash
ls -l /opt/server-health-check/
```

```text
-rw------- 1 root root 2158 Aug 31 09:05 health_check.conf
-rwxr-xr-x 1 root root 9840 Aug 31 09:05 health_check.sh
-rw-r--r-- 1 root root 1580 Aug 31 09:05 targets.conf
```

## Step 4. targets.confの内容確認

```bash
cat /opt/server-health-check/targets.conf
```

```text
# --- Webサーバー群(HTTPステータスコードで監視) ---
web01,http,http://192.168.1.11/,200
web02,http,https://192.168.1.12/,200
api01,http,http://192.168.1.13:8080/healthz,200

# --- DB・アプリケーションサーバー群(pingで監視) ---
# HTTPサービスを持たないサーバーは ping で「ネットワーク的に生きているか」だけを見る
db01,ping,192.168.1.21,-
app01,ping,192.168.1.22,-
```

これが「実運用で使う想定の監視対象リスト」。実際の現場では、この`192.168.1.x`の部分を本物のサーバーのIPアドレス(またはホスト名)に書き換えて使う。

💡ポイント: 行の先頭を`#`にするとコメント行として無視される。サーバーを一時的に監視対象から外したいときは、削除せずに行頭へ`#`を付けてコメントアウトする運用にすると、あとで簡単に元に戻せる。

## Step 5. 動作確認用の環境を用意する(検証用VM1台だけの場合)

本物のサーバーが複数台無くても手元で動作確認できるよう、`python3`の簡易HTTPサーバーを使って「疑似的なWebサーバー」を1台分立て、`targets.conf`を一時的に検証用の内容へ差し替える。

```bash
# 疑似Webサーバー用のディレクトリを作成し、確認用ページを1枚置く
sudo mkdir -p /tmp/health-check-demo/www
echo "<h1>demo ok</h1>" | sudo tee /tmp/health-check-demo/www/index.html

# ポート8080でPythonの簡易HTTPサーバーを起動(バックグラウンド実行)
sudo python3 -m http.server 8080 --directory /tmp/health-check-demo/www &
```

```text
<h1>demo ok</h1>
Serving HTTP on 0.0.0.0 port 8080 (http://0.0.0.0:8080/) ...
```

続けて、`targets.conf`を検証用の内容に一時的に書き換える(元の内容はStep 4で確認済みなので、Step 12で書き戻す)。

```bash
sudo tee /opt/server-health-check/targets.conf > /dev/null <<'EOF'
# --- 動作確認用(検証用VM1台だけで完結させるための設定) ---
local-web,http,http://127.0.0.1:8080/,200
local-ping,ping,127.0.0.1,-
down-web,http,http://127.0.0.1:8081/,200
EOF
```

**何をしているか**: 3台分の監視対象を用意している。

| 名前 | 内容 | 想定 |
|---|---|---|
| `local-web` | Step 5で起動したPythonの簡易サーバー(ポート8080) | 常にOKになる想定(正常系の確認用) |
| `local-ping` | 自ホスト(`127.0.0.1`)へのping | 常にOKになる想定(正常系の確認用) |
| `down-web` | あえて何も起動していないポート8081 | 常にNGになる想定(異常検知・通知の確認用) |

💡ポイント: `<<'EOF'`のように`EOF`をシングルクォートで囲むと、ヒアドキュメントの中の`$`記号などがそのまま文字として扱われる(展開されない)。今回は特に変数展開が必要ないため、事故防止のためにシングルクォート版を使っている([02-design.md](./02-design.md) 4.5節参照)。

## Step 6. Slack Webhook URLの取得と設定

1. Slackで通知を送りたいワークスペースを開き、「App管理」→「Incoming Webhooks」を追加する
2. 通知先チャンネルを選択し、発行されたWebhook URL(`https://hooks.slack.com/services/...`)をコピーする
3. `health_check.conf`を編集し、`SLACK_WEBHOOK_URL`の値を実際のURLに書き換える

```bash
sudo vi /opt/server-health-check/health_check.conf
```

```bash
# 編集前(初期状態はプレースホルダーのまま)
SLACK_WEBHOOK_URL="<YOUR_SLACK_WEBHOOK_URL>"

# 編集後: <YOUR_SLACK_WEBHOOK_URL> の部分を、手順2でコピーした
# https://hooks.slack.com/services/ から始まる実際のURLに書き換える
```

疎通確認だけを先に行いたい場合は、単体で以下を実行するとよい。

```bash
curl -s -X POST -H 'Content-type: application/json' \
    --data '{"text": "通知テストです"}' \
    "<YOUR_SLACK_WEBHOOK_URL>"
```

Slackの対象チャンネルに「通知テストです」と投稿されれば疎通OK。

💡ポイント: Slackの準備がまだの場合は、`health_check.conf`の`ENABLE_SLACK_NOTIFY`を`false`にしておけば、通知処理はスキップされてログ記録・レポート生成だけを先に確認できる。

## Step 7. 1回目の手動実行(正常系+経過観察の確認)

cronに登録する前に、まず手動実行して正しく動くか確認する。

```bash
sudo /opt/server-health-check/health_check.sh
```

```text
2026-08-31 10:15:03 [INFO] ===== サーバー死活監視を開始します =====
2026-08-31 10:15:03 [INFO] local-web(http://127.0.0.1:8080/)は正常です
2026-08-31 10:15:04 [INFO] local-ping(127.0.0.1)は正常です
2026-08-31 10:15:06 [WARN] down-web(http://127.0.0.1:8081/)がNGです(連続1回目。通知の閾値は2回)
2026-08-31 10:15:06 [INFO] 監視完了: 対象3台中、NG 1台
2026-08-31 10:15:06 [INFO] レポートを生成しました: /opt/server-health-check/report/report.md
2026-08-31 10:15:06 [INFO] ===== サーバー死活監視を終了します =====
```

**何をしているか**: `health_check.sh`をroot権限で手動起動している。`down-web`は1回目のNGなので、まだ閾値(2回)に達しておらず、通知は送られない(ログも`WARN`止まり)。

**state.csvの確認**:

```bash
cat /var/lib/server-health-check/state.csv
```

```text
local-web,OK,0,no
local-ping,OK,0,no
down-web,NG,1,no
```

💡ポイント: `down-web`の連続失敗回数が`1`、通知済みフラグが`no`になっていることが確認できる。「1回失敗しただけではまだ様子見」という設計([02-design.md](./02-design.md) 4.3節)が、この時点のデータからも読み取れる。

## Step 8. 2回目の手動実行(閾値超え・異常通知の確認)

実運用では5分後に自動実行されるが、ここでは動作確認のためすぐに再実行する。

```bash
sudo /opt/server-health-check/health_check.sh
```

```text
2026-08-31 10:20:11 [INFO] ===== サーバー死活監視を開始します =====
2026-08-31 10:20:11 [INFO] local-web(http://127.0.0.1:8080/)は正常です
2026-08-31 10:20:12 [INFO] local-ping(127.0.0.1)は正常です
2026-08-31 10:20:14 [ERROR] down-web(http://127.0.0.1:8081/)が2回連続でNGです。閾値(2回)を超えたため異常として通知します
2026-08-31 10:20:14 [INFO] 監視完了: 対象3台中、NG 1台
2026-08-31 10:20:14 [INFO] レポートを生成しました: /opt/server-health-check/report/report.md
2026-08-31 10:20:14 [INFO] ===== サーバー死活監視を終了します =====
```

**確認できたこと**: `down-web`の連続失敗回数が閾値(2回)に達し、ログレベルが`ERROR`に変わって異常通知(`notify_slack`)が呼ばれている。`ENABLE_SLACK_NOTIFY=true`にしていれば、Slackに以下のようなメッセージが届く。

```text
🔴 [障害検知] down-web(http://127.0.0.1:8081/)が2回連続でNGです
```

```bash
cat /var/lib/server-health-check/state.csv
```

```text
local-web,OK,0,no
local-ping,OK,0,no
down-web,NG,2,yes
```

`notified`が`yes`に変わったことが確認できる。

## Step 9. 3回目の手動実行(通知が連発しないことの確認)

```bash
sudo /opt/server-health-check/health_check.sh
```

```text
2026-08-31 10:25:20 [INFO] ===== サーバー死活監視を開始します =====
2026-08-31 10:25:20 [INFO] local-web(http://127.0.0.1:8080/)は正常です
2026-08-31 10:25:21 [INFO] local-ping(127.0.0.1)は正常です
2026-08-31 10:25:23 [WARN] down-web(http://127.0.0.1:8081/)がNGです(連続3回目。通知の閾値は2回)
2026-08-31 10:25:23 [INFO] 監視完了: 対象3台中、NG 1台
2026-08-31 10:25:23 [INFO] レポートを生成しました: /opt/server-health-check/report/report.md
2026-08-31 10:25:23 [INFO] ===== サーバー死活監視を終了します =====
```

**確認できたこと**: 連続失敗回数は`3`に増えているが、ログレベルは`WARN`に戻り、`notify_slack`は呼ばれていない(=Slackへ再送されない)。「状態が変化したタイミングだけ通知する」設計([02-design.md](./02-design.md) 5章)が意図通り動いていることが分かる。

💡ポイント: もしここで毎回通知が飛んでいたら、5分ごとに同じ「障害検知」メッセージがSlackに届き続けることになる。実際の現場でこれが起きると、通知チャンネルが埋め尽くされて他の重要な通知が埋もれてしまう。

## Step 10. 復旧の確認

ポート8081でも簡易サーバーを起動し、`down-web`を復旧させる。

```bash
sudo mkdir -p /tmp/health-check-demo/www2
sudo python3 -m http.server 8081 --directory /tmp/health-check-demo/www2 &
```

```text
Serving HTTP on 0.0.0.0 port 8081 (http://0.0.0.0:8081/) ...
```

```bash
sudo /opt/server-health-check/health_check.sh
```

```text
2026-08-31 10:30:31 [INFO] ===== サーバー死活監視を開始します =====
2026-08-31 10:30:31 [INFO] local-web(http://127.0.0.1:8080/)は正常です
2026-08-31 10:30:32 [INFO] local-ping(127.0.0.1)は正常です
2026-08-31 10:30:32 [INFO] down-web(http://127.0.0.1:8081/)が復旧しました
2026-08-31 10:30:32 [INFO] 監視完了: 対象3台中、NG 0台
2026-08-31 10:30:32 [INFO] レポートを生成しました: /opt/server-health-check/report/report.md
2026-08-31 10:30:32 [INFO] ===== サーバー死活監視を終了します =====
```

`ENABLE_SLACK_NOTIFY=true`であれば、Slackに以下のような復旧通知が届く。

```text
✅ [復旧] down-web(http://127.0.0.1:8081/)が復旧しました
```

```bash
cat /var/lib/server-health-check/state.csv
```

```text
local-web,OK,0,no
local-ping,OK,0,no
down-web,OK,0,no
```

すべて`OK`・連続失敗`0`・通知済みフラグ`no`に戻っていることを確認する。

## Step 11. レポート(report.md)と稼働率の確認

```bash
cat /opt/server-health-check/report/report.md
```

```text
# サーバー死活監視レポート

- 生成日時: 2026-08-31 10:30:32
- 監視対象数: 3台
- 異常判定中: 0台
- 連続失敗の通知閾値: 2回

## 現在の状態一覧

| サーバー名 | 監視方法 | 監視対象 | 状態 | 連続失敗回数 | 直近24時間稼働率 |
|---|---|---|---|---|---|
| local-web | http | http://127.0.0.1:8080/ | 🟢 OK | 0回 | 100.0% |
| local-ping | ping | 127.0.0.1 | 🟢 OK | 0回 | 100.0% |
| down-web | http | http://127.0.0.1:8081/ | 🟢 OK | 0回 | 25.0% |

## 状態アイコンの見方

| アイコン | 意味 |
|---|---|
| 🟢 OK | 直近のチェックが成功している |
| 🟡 経過観察 | 失敗はしているが、まだ通知の閾値(2回)未満。誤検知の可能性を考慮しまだ通知はしていない |
| 🔴 異常 | 連続失敗回数が閾値以上に達し、Slackへ異常通知を送信済み |

このレポートは health_check.sh が実行されるたび(既定は5分ごと)に自動的に上書き生成される。
```

**確認できたこと**: `down-web`は現在は`🟢 OK`だが、直近24時間の稼働率は`25.0%`(記録された4回のチェックのうちOKは1回だけだったため)になっている。**「今は復旧しているが、過去に何度も落ちていた」という事実がレポートから読み取れる**、というのがFR-10(発展要件)のねらい。

```bash
cat /var/log/server-health-check/history.csv
```

```text
timestamp,name,type,target,status
2026-08-31 10:15:03,local-web,http,http://127.0.0.1:8080/,OK
2026-08-31 10:15:04,local-ping,ping,127.0.0.1,OK
2026-08-31 10:15:06,down-web,http,http://127.0.0.1:8081/,NG
2026-08-31 10:20:11,local-web,http,http://127.0.0.1:8080/,OK
2026-08-31 10:20:12,local-ping,ping,127.0.0.1,OK
2026-08-31 10:20:14,down-web,http,http://127.0.0.1:8081/,NG
2026-08-31 10:25:20,local-web,http,http://127.0.0.1:8080/,OK
2026-08-31 10:25:21,local-ping,ping,127.0.0.1,OK
2026-08-31 10:25:23,down-web,http,http://127.0.0.1:8081/,NG
2026-08-31 10:30:31,local-web,http,http://127.0.0.1:8080/,OK
2026-08-31 10:30:32,local-ping,ping,127.0.0.1,OK
2026-08-31 10:30:32,down-web,http,http://127.0.0.1:8081/,OK
```

💡ポイント: `history.csv`にすべてのチェック結果が1行ずつ蓄積されており、これが稼働率計算の元データになっている。手動で`grep down-web history.csv`のようにフィルタすれば、特定のサーバーだけの履歴も確認できる。

## Step 12. 検証用サーバーの停止とtargets.confの復元

動作確認が終わったら、検証用に立てたPythonサーバーを止め、`targets.conf`を実運用向けの内容に戻す。

```bash
# バックグラウンドで動いているPythonサーバーを停止する
sudo pkill -f "http.server 8080"
sudo pkill -f "http.server 8081"

# targets.confを実運用向けの内容に戻す(元々の内容。Step 4参照)
sudo cp src/targets.conf /opt/server-health-check/targets.conf
sudo chmod 644 /opt/server-health-check/targets.conf
```

💡ポイント: `sed -i`で一時的に値を変えたときと同様(案件No.2のノウハウ)、テストのために変更した設定は**必ず元に戻す**ところまでを手順の一部と考える。戻し忘れは実務でも起きがちなミス。実サーバーのIPアドレスに書き換えたあと、Step 7〜11と同じ手順で実際の対象に対しても動作確認を行う。

## Step 13. cronへの登録

動作確認が済んだら、`crontab.example`の内容を実際のcrontabに登録する。

```bash
sudo crontab -e
```

エディタが開くので、末尾に以下を追記する(`src/crontab.example`と同じ内容)。

```text
*/5 * * * * /opt/server-health-check/health_check.sh >> /var/log/server-health-check/cron.log 2>&1
```

保存して終了したら、登録内容を確認する。

```bash
sudo crontab -l
```

```text
*/5 * * * * /opt/server-health-check/health_check.sh >> /var/log/server-health-check/cron.log 2>&1
```

💡ポイント: `crontab -e`はrootとそれ以外のユーザーで別々の予定表を持つ。監視対象への通信や`/var/log`・`/var/lib`配下への書き込みができないユーザーで登録すると、cron実行時だけ失敗する原因になる([05-troubleshooting.md](./05-troubleshooting.md) Q1も参照)。

登録後は数分待ち、`cron.log`と`health_check.log`に実行記録が増えていくことを確認する。

```bash
tail -n 5 /var/log/server-health-check/health_check.log
```

## Step 14. 最終確認チェックリスト

| 確認項目 | コマンド | 期待結果 |
|---|---|---|
| スクリプトの実行権限 | `ls -l /opt/server-health-check/health_check.sh` | `rwxr-xr-x` |
| 設定ファイルの権限 | `ls -l /opt/server-health-check/health_check.conf` | `rw-------` |
| 手動実行が成功する | `sudo /opt/server-health-check/health_check.sh; echo $?` | `0` |
| targets.confが実運用向けの内容に戻っている | `cat /opt/server-health-check/targets.conf` | 本番の監視対象一覧が表示される(検証用のlocal-web等が残っていない) |
| レポートが生成される | `cat /opt/server-health-check/report/report.md` | Markdown表形式のレポートが表示される |
| 履歴が蓄積されている | `wc -l /var/log/server-health-check/history.csv` | 実行のたびに行数が増えている |
| cronに登録されている | `sudo crontab -l` | `*/5 * * * *` の行が存在 |

すべて満たしていれば構築完了。詳細なテストケースは[04-test-plan.md](./04-test-plan.md)を参照。
