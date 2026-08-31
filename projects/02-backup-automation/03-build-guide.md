# 03. 構築手順書

本手順は、Ubuntu Server 22.04 LTS上に「運用中のWebサーバー(`/var/www/html`)」が既に存在することを前提に進める。手元にそのサーバーが無い場合は、`sudo mkdir -p /var/www/html && sudo sh -c 'echo "<h1>test</h1>" > /var/www/html/index.html'` のようなダミーファイルで代用してよい。

コマンドは基本的に`sudo`権限で実行する想定(実行例では省略している箇所がある)。

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

💡ポイント: 検証環境([01-requirements.md](./01-requirements.md)参照)とズレがないか、作業の最初に確認しておくと後々のトラブルシューティングが楽になる。

## Step 1. 配置先ディレクトリの作成

```bash
sudo mkdir -p /opt/backup-automation
sudo mkdir -p /var/backups/html-backup
sudo mkdir -p /var/log/backup-automation
```

**何をしているか**: スクリプト本体・バックアップ保存先・ログ保存先の3つのディレクトリを作成している。`-p`オプションにより、親ディレクトリが無くても一括作成でき、既に存在していてもエラーにならない。

**なぜ**: 「スクリプト」「バックアップデータ」「ログ」を別ディレクトリに分けておくことで、それぞれに適切な権限(後述)を設定しやすくなる。

## Step 2. スクリプト・設定ファイルの配置

本リポジトリの`src/`配下のファイルを対象サーバーへ配置する。ここではリポジトリを`scp`でサーバーに送る方法と、内容を直接貼り付ける方法のどちらでもよい。

```bash
sudo cp src/backup.sh /opt/backup-automation/backup.sh
sudo cp src/backup.conf /opt/backup-automation/backup.conf
```

**何をしているか**: 本体スクリプトと設定ファイルをそれぞれ配置先へコピーしている。

**確認**:

```bash
ls -l /opt/backup-automation/
```

```text
-rw-r--r-- 1 root root 1240 Aug 31 10:00 backup.conf
-rw-r--r-- 1 root root 4920 Aug 31 10:00 backup.sh
```

## Step 3. 実行権限・アクセス権限の設定

```bash
sudo chmod 755 /opt/backup-automation/backup.sh
sudo chmod 600 /opt/backup-automation/backup.conf
```

**何をしているか**:
- `backup.sh`に実行権限(`x`)を付与し、`./backup.sh`のように直接実行できるようにする。
- `backup.conf`はSlack WebhookのURL(秘匿情報)を含むため、所有者(root)以外は読めないように`600`(所有者のみ読み書き可)に制限する。

💡ポイント: `chmod 600`を忘れると、サーバーの他の利用者からWebhook URLが読めてしまう。パーミッション設定は「動けばOK」ではなく、セキュリティの観点でも必ずセットで確認する習慣をつける。

**確認**:

```bash
ls -l /opt/backup-automation/
```

```text
-rw------- 1 root root 1240 Aug 31 10:00 backup.conf
-rwxr-xr-x 1 root root 4920 Aug 31 10:00 backup.sh
```

## Step 4. Slack Webhook URLの取得と設定

1. Slackで通知を送りたいワークスペースを開き、「App管理」→「Incoming Webhooks」を追加する
2. 通知先チャンネルを選択し、発行されたWebhook URL(`https://hooks.slack.com/services/...`)をコピーする
3. `backup.conf`を編集し、`SLACK_WEBHOOK_URL`の値を実際のURLに書き換える

```bash
sudo vi /opt/backup-automation/backup.conf
```

```bash
# 編集前(初期状態はプレースホルダーのまま)
SLACK_WEBHOOK_URL="<YOUR_SLACK_WEBHOOK_URL>"

# 編集後: <YOUR_SLACK_WEBHOOK_URL> の部分を、手順2でコピーした
# https://hooks.slack.com/services/ から始まる実際のURLに書き換える
```

**なぜ**: バックアップ失敗という「気づきにくい障害」を、人が見に行かなくても検知できるようにするため。通知先を用意しておくことで、Step 6以降の異常系テストも実際に確認できるようになる。

💡ポイント: 通知の疎通確認だけを先に行いたい場合は、単体で以下を実行するとよい。

```bash
curl -s -X POST -H 'Content-type: application/json' \
    --data '{"text": "通知テストです"}' \
    "<YOUR_SLACK_WEBHOOK_URL>"
```

Slackの対象チャンネルに「通知テストです」と投稿されれば疎通OK。

## Step 5. 手動実行での動作確認

cronに登録する前に、まず手動実行して正しく動くか確認する。

```bash
sudo /opt/backup-automation/backup.sh
```

```text
2026-08-31 10:15:03 [INFO] ===== バックアップ処理を開始します =====
2026-08-31 10:15:03 [INFO] バックアップを作成します: /var/backups/html-backup/html-backup-20260831.tar.gz
2026-08-31 10:15:03 [INFO] バックアップ作成に成功しました(サイズ: 4.0K)
2026-08-31 10:15:03 [INFO] 7日より古いバックアップを検索・削除します
2026-08-31 10:15:03 [INFO] 削除対象の古いバックアップはありませんでした
2026-08-31 10:15:03 [INFO] バックアップ先の使用率: 20%(警告閾値: 80%)
2026-08-31 10:15:03 [INFO] ===== バックアップ処理が正常に終了しました =====
```

**何をしているか**: `backup.sh`をroot権限で手動起動し、標準出力にログが表示されることを確認している(内部の`log`関数が`tee`で画面とログファイルの両方に出力する仕組みのため)。

**終了コードの確認**:

```bash
echo $?
```

```text
0
```

💡ポイント: シェルスクリプトでは、直前に実行したコマンドの終了コード(`0`=成功、`0以外`=失敗)を`$?`で確認できる。`0`が返ってくることで「正常終了した」と判断できる。

## Step 6. バックアップファイルの確認

```bash
ls -lh /var/backups/html-backup/
```

```text
-rw-r--r-- 1 root root 164 Aug 31 10:15 html-backup-20260831.tar.gz
```

ファイル名に本日の日付(`YYYYMMDD`)が入っていることを確認する。中身を確認したい場合は以下で展開せずに一覧表示できる。

```bash
tar tzvf /var/backups/html-backup/html-backup-20260831.tar.gz
```

```text
drwxr-xr-x root/root         0 2026-08-31 10:15 html/
-rw-r--r-- root/root        20 2026-08-31 10:15 html/index.html
```

**何をしているか**: `tar t`は展開せずにアーカイブの中身一覧を表示するオプション。実際にファイルを取り出さなくても、中身が正しいかを確認できる。

## Step 7. ログファイルの確認

```bash
cat /var/log/backup-automation/backup.log
```

Step 5の実行結果と同じ内容がファイルにも記録されていれば正しく動作している。

## Step 8. 世代管理(自動削除)の動作確認

7日待たないと動作確認できないのは非現実的なので、`touch -d`コマンドで「古い日付のファイル」を擬似的に作り、削除されることを確認する。

```bash
# 8日前・9日前のタイムスタンプを持つダミーファイルを作成(削除される想定)
sudo touch -d "8 days ago" /var/backups/html-backup/html-backup-20260823.tar.gz
sudo touch -d "9 days ago" /var/backups/html-backup/html-backup-20260822.tar.gz

# 5日前のタイムスタンプを持つダミーファイルも作成(残る想定)
sudo touch -d "5 days ago" /var/backups/html-backup/html-backup-20260826.tar.gz

ls -la /var/backups/html-backup/
```

```text
-rw-r--r-- 1 root root    0 Aug 22 10:20 html-backup-20260822.tar.gz
-rw-r--r-- 1 root root    0 Aug 23 10:20 html-backup-20260823.tar.gz
-rw-r--r-- 1 root root    0 Aug 26 10:20 html-backup-20260826.tar.gz
-rw-r--r-- 1 root root  164 Aug 31 10:15 html-backup-20260831.tar.gz
```

再度スクリプトを実行する。

```bash
sudo /opt/backup-automation/backup.sh
```

```text
2026-08-31 10:22:10 [INFO] ===== バックアップ処理を開始します =====
2026-08-31 10:22:10 [INFO] バックアップを作成します: /var/backups/html-backup/html-backup-20260831.tar.gz
2026-08-31 10:22:10 [INFO] バックアップ作成に成功しました(サイズ: 4.0K)
2026-08-31 10:22:10 [INFO] 7日より古いバックアップを検索・削除します
2026-08-31 10:22:10 [INFO] 古いバックアップを削除します: /var/backups/html-backup/html-backup-20260822.tar.gz
2026-08-31 10:22:10 [INFO] 古いバックアップを削除します: /var/backups/html-backup/html-backup-20260823.tar.gz
2026-08-31 10:22:10 [INFO] バックアップ先の使用率: 20%(警告閾値: 80%)
2026-08-31 10:22:10 [INFO] ===== バックアップ処理が正常に終了しました =====
```

```bash
ls -la /var/backups/html-backup/
```

```text
-rw-r--r-- 1 root root    0 Aug 26 10:20 html-backup-20260826.tar.gz
-rw-r--r-- 1 root root  164 Aug 31 10:22 html-backup-20260831.tar.gz
```

**確認できたこと**: 8日前・9日前(`RETENTION_DAYS=7`を超えた分)は削除され、5日前のファイルと本日分は残っている。`find -mtime +7`が意図通り「7日より古いものだけ」を対象にしていることが実データで確認できた。

💡ポイント: 本番のバックアップファイルではなく、必ずこのような**ダミーファイル**で検証すること。実データで試すと、テスト目的で本物のバックアップを消してしまう事故につながる。

## Step 9. 空き容量警告(発展要件)の動作確認

実際にディスクを80%以上使わせるのは大変なので、設定ファイルの閾値を一時的に下げてテストする。

```bash
# 一時的に閾値を1%に下げる(通常運用では絶対に使わない値)
sudo sed -i 's/DISK_USAGE_THRESHOLD=80/DISK_USAGE_THRESHOLD=1/' /opt/backup-automation/backup.conf

sudo /opt/backup-automation/backup.sh
```

```text
2026-08-31 10:25:40 [INFO] バックアップ先の使用率: 20%(警告閾値: 1%)
2026-08-31 10:25:40 [WARN] バックアップ先の空き容量が閾値を超えています(20% >= 1%)
```

Slackにも`:warning: [容量警告] ...`という通知が届いていることを確認する。確認できたら、必ず設定値を元(`80`)に戻す。

```bash
sudo sed -i 's/DISK_USAGE_THRESHOLD=1/DISK_USAGE_THRESHOLD=80/' /opt/backup-automation/backup.conf
```

💡ポイント: `sed -i`は「ファイルの中身を直接置換する」コマンド。テストのために一時的に値を変えたら、**忘れずに元に戻す**ところまでが手順の一部と考える。戻し忘れは実務でも起きがちなミス。

## Step 10. 失敗時通知の動作確認(異常系)

対象ディレクトリを一時的に存在しないパスに変更し、失敗パターンも確認しておく。

```bash
sudo sed -i 's#BACKUP_SRC_DIR="/var/www/html"#BACKUP_SRC_DIR="/var/www/no-such-dir"#' /opt/backup-automation/backup.conf

sudo /opt/backup-automation/backup.sh
echo "終了コード: $?"
```

```text
2026-08-31 10:28:02 [INFO] ===== バックアップ処理を開始します =====
2026-08-31 10:28:02 [ERROR] バックアップ対象ディレクトリが存在しません: /var/www/no-such-dir
終了コード: 1
```

Slackに`:x: [バックアップ失敗] ...`という通知が届くことを確認したら、設定を元に戻す。

```bash
sudo sed -i 's#BACKUP_SRC_DIR="/var/www/no-such-dir"#BACKUP_SRC_DIR="/var/www/html"#' /opt/backup-automation/backup.conf
```

## Step 11. cronへの登録

動作確認が済んだら、`crontab.example`の内容を実際のcrontabに登録する。

```bash
sudo crontab -e
```

エディタが開くので、末尾に以下を追記する(`src/crontab.example`と同じ内容)。

```text
0 3 * * * /opt/backup-automation/backup.sh >> /var/log/backup-automation/cron.log 2>&1
```

保存して終了したら、登録内容を確認する。

```bash
sudo crontab -l
```

```text
0 3 * * * /opt/backup-automation/backup.sh >> /var/log/backup-automation/cron.log 2>&1
```

💡ポイント: `crontab -e`はrootとそれ以外のユーザーで別々の予定表を持つ。`backup.sh`が対象ディレクトリを読み書きできる権限のユーザーで登録しないと、cron実行時だけ失敗する原因になる([05-troubleshooting.md](./05-troubleshooting.md) Q1も参照)。

## Step 12. ログローテーションの設定

```bash
sudo cp src/logrotate-backup-automation.conf /etc/logrotate.d/backup-automation
```

設定ファイルの文法チェックとドライラン(実際には実行せず、何が起きるかだけ確認するモード)を行う。

```bash
sudo logrotate -d /etc/logrotate.d/backup-automation
```

```text
reading config file /etc/logrotate.d/backup-automation
Handling 1 logs

rotating pattern: /var/log/backup-automation/backup.log  after 1 days (30 rotations)
empty log files are not rotated, old logs are removed
considering log /var/log/backup-automation/backup.log
  log does not need rotating (log has been already rotated)
```

**何をしているか**: `-d`(dry-runモード)で、実際にファイルを操作せずに設定が正しく解釈されるかを確認している。エラーが出ないことを確認できれば設定は完了。

## Step 13. 最終確認チェックリスト

| 確認項目 | コマンド | 期待結果 |
|---|---|---|
| スクリプトの実行権限 | `ls -l /opt/backup-automation/backup.sh` | `rwxr-xr-x` |
| 設定ファイルの権限 | `ls -l /opt/backup-automation/backup.conf` | `rw-------` |
| 手動実行が成功する | `sudo /opt/backup-automation/backup.sh; echo $?` | `0` |
| バックアップファイルが生成される | `ls /var/backups/html-backup/` | 本日日付のファイルが存在 |
| cronに登録されている | `sudo crontab -l` | `0 3 * * *` の行が存在 |
| logrotate設定が有効 | `sudo logrotate -d /etc/logrotate.d/backup-automation` | エラーなし |

すべて満たしていれば構築完了。詳細なテストケースは[04-test-plan.md](./04-test-plan.md)を参照。
