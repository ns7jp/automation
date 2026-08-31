# 05. トラブルシューティング集

構築・運用中によく遭遇するトラブルをQ&A形式でまとめる。

---

## Q1. 手動実行では成功するのに、cron経由だと失敗する

**現象**

```bash
sudo /opt/backup-automation/backup.sh   # これは成功する
```

しかしcronから自動実行されたときだけ、`cron.log`に以下のようなエラーが残る。

```text
/opt/backup-automation/backup.sh: line 45: tar: command not found
```

**原因**

`cron`は、ログインシェル(SSHでログインしたときのシェル)とは異なり、`PATH`環境変数が最小限しか設定されていない状態でコマンドを実行する。そのため、`.bashrc`などで独自にPATHを拡張している場合、cron実行時にはそのPATHが反映されず、`tar`や`curl`などのコマンドが見つからないことがある。

**対処法**

1. 該当コマンドがどこにあるか確認する

   ```bash
   which tar curl find df
   ```

   ```text
   /usr/bin/tar
   /usr/bin/curl
   /usr/bin/find
   /usr/bin/df
   ```

2. 通常は`/usr/bin`や`/bin`は標準のcron PATHに含まれているため、この問題は「独自にインストールしたツールを使っている場合」に起きやすい。もし発生した場合は、crontab内でPATHを明示的に指定する。

   ```text
   PATH=/usr/local/bin:/usr/bin:/bin
   0 3 * * * /opt/backup-automation/backup.sh >> /var/log/backup-automation/cron.log 2>&1
   ```

💡ポイント: 「手元では動くのにcronだと動かない」というのは初心者がほぼ必ず一度は経験するcron特有のハマりどころ。原因の多くはPATHか、カレントディレクトリの違い(cronの作業ディレクトリは実行ユーザーのホームディレクトリになる)にある。

---

## Q2. `tar: Removing leading '/' from member names` という警告が出る

**現象**

```bash
tar czf backup.tar.gz /var/www/html
```

```text
tar: Removing leading `/' from member names
```

**原因**

`tar`に絶対パス(`/`から始まるパス)を渡すと、アーカイブ展開時に意図せずシステムの元の場所へファイルを上書きしてしまう事故を防ぐため、`tar`が自動的に先頭の`/`を取り除いて警告を出す仕様になっている。

**対処法**

エラーではなく警告なので、動作自体に支障はない。ただし、本手順([02-design.md](./02-design.md) 4.2節)で紹介している`-C`オプションを使う書き方にすれば、そもそもこの警告自体が発生しなくなる。

```bash
# 警告が出る書き方
tar czf backup.tar.gz /var/www/html

# 警告が出ない書き方(本スクリプトの採用方式)
tar -czf backup.tar.gz -C /var/www html
```

---

## Q3. `find -mtime +7` を指定したのに、期待通りの日数でファイルが消えない

**現象**

7日分残すつもりで`-mtime +7`を指定したが、実際に消えるタイミングが1日ずれているように見える。

**原因**

`-mtime`は「更新日時からの経過時間を24時間単位で切り捨てて」日数を判定する。さらに`+N`は「Nを超える(N日より古い)」という意味であり、「N日以内」ではない。例えば`-mtime +7`は「7日と少しでも過ぎたら対象」ではなく、「丸7日+1日、つまり8日目に入ったファイル」が対象になる、という挙動になる。

**対処法**

- 「何日分残したいか」を先に決め、`RETENTION_DAYS`の値と`-mtime +${RETENTION_DAYS}`の関係を再確認する(`RETENTION_DAYS=7`なら8日目以降が削除される、という前提を関係者と共有しておく)
- より厳密に制御したい場合は、`-mtime`ではなく分単位で判定できる`-mmin`を使う方法もある(例: `-mmin +$((7*24*60))`)
- 迷ったら、まず`rm`をつけずに`find ... -print`だけを実行し、対象になるファイルを目視確認してから削除処理につなげる

```bash
find /var/backups/html-backup -type f -name "html-backup-*.tar.gz" -mtime +7 -print
```

---

## Q4. Slack通知が届かない

**現象**

`backup.sh`はエラーなく終了する(あるいはログには`ERROR`/`WARN`が出ている)のに、Slackにメッセージが届かない。

**原因(よくあるもの)**

| 原因 | 確認方法 |
|---|---|
| Webhook URLの入力ミス(コピー漏れ・余分な空白) | `backup.conf`の`SLACK_WEBHOOK_URL`を目視確認 |
| Slack側でIncoming Webhookが無効化・削除されている | Slackの管理画面で該当Webhookの状態を確認 |
| `ENABLE_SLACK_NOTIFY`が`false`になっている | `backup.conf`を確認 |
| サーバーからインターネットへ外部通信できない(プロキシ・ファイアウォール制限) | 下記のcurl単体テストで疎通確認 |

**対処法**

まず`curl`単体でSlackへの疎通を確認する。

```bash
curl -v -X POST -H 'Content-type: application/json' \
    --data '{"text": "疎通テスト"}' \
    "$(grep SLACK_WEBHOOK_URL /opt/backup-automation/backup.conf | cut -d'"' -f2)"
```

```text
* Connected to hooks.slack.com (xxx.xxx.xxx.xxx) port 443
> POST /services/... HTTP/1.1
< HTTP/1.1 200 OK
ok
```

`ok`が返ってくれば疎通は問題ない。`curl: (6) Could not resolve host`のようなエラーが出る場合は、DNSやプロキシ設定などネットワーク側の問題を疑う。

---

## Q5. `backup.sh`を実行すると `Permission denied` と表示される

**現象**

```bash
/opt/backup-automation/backup.sh
```

```text
-bash: /opt/backup-automation/backup.sh: Permission denied
```

**原因**

スクリプトファイルに実行権限(`x`)が付与されていない。

**対処法**

```bash
ls -l /opt/backup-automation/backup.sh
```

```text
-rw-r--r-- 1 root root 4920 Aug 31 10:00 backup.sh
```

`x`が無いことを確認したら、実行権限を付与する。

```bash
sudo chmod +x /opt/backup-automation/backup.sh
```

💡ポイント: 権限が無くても`bash /opt/backup-automation/backup.sh`のように、明示的にインタプリタ経由で実行すれば動作はする。ただし、cronから安定して実行するためにも`chmod +x`はきちんと行っておく。

---

## Q6. バックアップ保存先のディスク容量がすぐに一杯になる

**現象**

`RETENTION_DAYS=7`を設定しているはずなのに、`/var/backups/html-backup`にファイルが溜まり続け、`df`で見ると使用率が下がらない。

**原因(よくあるもの)**

- `find`の`-name`パターンと、実際に生成されるファイル名の命名規則が一致していない(例: 手動で別名のバックアップを混ぜて置いてしまった)
- 過去に手動で取得した古い形式のバックアップファイルが対象パターンに含まれておらず、削除処理の対象外になっている
- `RETENTION_DAYS`の値を大きくしすぎている、または削除処理そのものがエラーで止まっている(ログの`ERROR`を確認)

**対処法**

1. 現在のファイル一覧と命名規則を確認する

   ```bash
   ls /var/backups/html-backup/
   ```

2. `backup.sh`内の`find`条件(`-name "html-backup-*.tar.gz"`)と、実際のファイル名が一致しているか確認する
3. ログファイルで削除処理がエラーなく実行されているか確認する

   ```bash
   grep "削除" /var/log/backup-automation/backup.log
   ```

命名規則が異なるファイルが残っている場合は、内容を確認した上で手動で整理し、以後は`backup.sh`が生成する命名規則に統一する。
