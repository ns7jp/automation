# 05. トラブルシューティング集

構築・運用中によく遭遇するトラブルをQ&A形式でまとめる。

---

## Q1. ログローテート直後だけ通知が来なくなる

**現象**

普段は正常に通知が届くのに、`logrotate`(日次でログを切り替える仕組み)が走った直後だけ、明らかに`ERROR`が出ているのに通知が来なくなる。

**原因**

`tail -f`(小文字)で監視している場合に起きやすい問題。`-f`は「開いた時点のファイル実体(ファイルディスクリプタ)」を追いかけるため、ローテートで元のファイルが別名にリネーム・削除され、同じ名前の新しいファイルが作られると、`tail -f`は**古い(もう更新されない)実体を見続けてしまい**、新しいファイルへの追記に気づけなくなる。

**対処法**

本ツールは`tail -F`(大文字)を使っているため、通常はこの問題は起きない。もし発生している場合は、監視スクリプトが実際に`-F`で起動しているか確認する。

```bash
ps -ef | grep "tail -F"
```

```text
logwatch  4823  4821  0 09:30 ?        00:00:00 tail -F -n 0 /var/log/app/error.log
```

`tail -F`で動作している場合、ローテート時には`journalctl`に以下のようなメッセージが記録され、自動的に新しいファイルへ追従する。

```text
tail: '/var/log/app/error.log' has become inaccessible: No such file or directory
tail: '/var/log/app/error.log' has appeared;  following new file
```

💡ポイント: `-f`と`-F`の違いは初心者が見落としやすい落とし穴([02-design.md](./02-design.md) 4.1節参照)。常駐監視では必ず`-F`を使う。

---

## Q2. サービス起動直後に `コマンド 'jq' が見つかりません` と表示されて終了する

**現象**

```bash
sudo systemctl start log-watch-alert
sudo journalctl -u log-watch-alert -n 5
```

```text
log-watch-alert.sh[4821]: [2026-08-31 09:10:02] [ERROR] コマンド 'jq' が見つかりません。インストールしてから再実行してください。
```

**原因**

`jq`(JSON整形・組み立てツール)がインストールされていない。`jq`はUbuntuに標準では入っていないことが多く、[03-build-guide.md](./03-build-guide.md) Step 1を飛ばして直接systemd登録に進んだ場合に起きやすい。

**対処法**

```bash
sudo apt-get update
sudo apt-get install -y jq
sudo systemctl restart log-watch-alert
```

```bash
jq --version
```

```text
jq-1.6
```

---

## Q3. Slackに通知が届かない

**現象**

`journalctl`には`[INFO] Slack通知を送信しました(HTTP 200)`と記録されているのに、実際にはSlackへ何も届いていない。あるいは`Slack通知の送信に失敗しました`とエラーが記録される。

**原因(よくあるもの)**

| 原因 | 確認方法 |
|---|---|
| `.env`の`SLACK_WEBHOOK_URL`の入力ミス(コピー漏れ・改行混入) | `cat /opt/log-watch-alert/.env`で目視確認 |
| Slack側でIncoming Webhookが無効化・削除されている | Slack管理画面で該当Webhookの状態を確認 |
| サーバーからインターネットへ外部通信できない(プロキシ・ファイアウォール制限) | 下記のcurl単体テストで疎通確認 |
| Webhookが別チャンネル向けに発行されており、見ているチャンネルが違う | Slack管理画面で通知先チャンネルを確認 |

**対処法**

まず`curl`単体でSlackへの疎通を確認する。

```bash
WEBHOOK_URL=$(grep SLACK_WEBHOOK_URL /opt/log-watch-alert/.env | cut -d'=' -f2-)
curl -v -X POST -H 'Content-type: application/json' \
    --data '{"text": "疎通テスト"}' \
    "$WEBHOOK_URL"
```

```text
* Connected to hooks.slack.com (xxx.xxx.xxx.xxx) port 443
> POST /services/... HTTP/1.1
< HTTP/1.1 200 OK
ok
```

`ok`と表示されればSlack側までは届いている。接続自体ができない場合は、以下のように接続エラーが出る。

```text
curl: (7) Failed to connect to 127.0.0.1 port 19999 after 0 ms: Couldn't connect to server
```

`journalctl`にも`[ERROR] Slack通知の送信に失敗しました(HTTP 000)`のように、HTTPステータスコードが`000`(通信自体が成立しなかった)と記録される。この場合はネットワーク経路(DNS・プロキシ・ファイアウォール)を疑う。

💡ポイント: 通知が失敗しても監視プロセス自体は止まらない設計にしている([01-requirements.md](./01-requirements.md) NFR-02)。「プロセスは動いているのに通知だけ来ない」状態でも、`journalctl`のエラーログから原因を追跡できる。

---

## Q4. 同じような検知の通知が大量に届き、スロットリングが効いていないように見える

**現象**

短時間に何件も同じ内容の通知がSlackに届く。5分に1回のはずが連続で届く。

**原因(よくあるもの)**

- `.env`の`THROTTLE_SECONDS`が意図せず小さい値になっている(動作確認用に短くしたまま戻し忘れている等)
- サービスが**重複して複数起動**しており、それぞれが別々に`state.tsv`を見て(あるいは別々の`STATE_DIR`を見て)通知してしまっている
- `state.tsv`が書き込み権限の問題で更新できておらず、常に「初回扱い」になっている

**対処法**

1. 現在の設定値を確認する

   ```bash
   grep THROTTLE_SECONDS /opt/log-watch-alert/.env
   ```

   ```text
   THROTTLE_SECONDS=300
   ```

2. プロセスが1つだけ動いているか確認する

   ```bash
   pgrep -af log-watch-alert.sh
   ```

   ```text
   4821 /bin/bash /opt/log-watch-alert/log-watch-alert.sh
   ```

   2行以上表示される場合は多重起動している。`sudo systemctl status log-watch-alert`で管理外のプロセスが残っていないか確認し、不要なプロセスは`kill`してからサービスを再起動する。

3. 状態ファイルが更新されているか確認する

   ```bash
   watch -n 1 cat /var/lib/log-watch-alert/state.tsv
   ```

   通知のたびに1列目(エポック秒)が更新されていれば正常。更新されない場合は、`logwatch`ユーザーが`/var/lib/log-watch-alert`に書き込めているか権限を確認する。

   ```bash
   ls -ld /var/lib/log-watch-alert
   ```

   ```text
   drwxr-xr-x 2 logwatch logwatch 4096 Aug 31 09:00 /var/lib/log-watch-alert
   ```

---

## Q5. `systemctl start log-watch-alert` を実行しても、すぐに停止してしまう

**現象**

```bash
sudo systemctl start log-watch-alert
sudo systemctl status log-watch-alert
```

```text
● log-watch-alert.service - Log Watch Alert - ERROR/CRITICALログ監視とSlack通知
     Active: failed (Result: exit-code) since ...
```

**原因(よくあるもの)**

| 原因 | 確認方法 |
|---|---|
| `EnvironmentFile=`で指定した`.env`が存在しない、パスが違う | `ls -l /opt/log-watch-alert/.env` |
| `ExecStart=`のパスが違う、スクリプトに実行権限が無い | `ls -l /opt/log-watch-alert/log-watch-alert.sh` |
| `.env`の`SLACK_WEBHOOK_URL`が空、または`LOG_FILE`が存在しない | Step 8相当を手動実行してエラーメッセージを確認 |

**対処法**

まず、systemd経由ではなく手動で直接実行し、エラーメッセージを直接確認するのが最短ルート。

```bash
sudo -u logwatch bash -c 'set -a; source /opt/log-watch-alert/.env; set +a; /opt/log-watch-alert/log-watch-alert.sh'
```

ここで表示されるエラーメッセージ(`SLACK_WEBHOOK_URL が設定されていません`等)が、`systemctl start`が失敗する直接の原因になっていることが多い。

詳細なログは`journalctl`で確認できる。

```bash
sudo journalctl -u log-watch-alert -n 30 --no-pager
```

💡ポイント: `systemctl status`だけでは原因の全容が見えないことが多い。「まず手動実行して、画面に出るエラーメッセージをそのまま読む」のがトラブルシューティングの基本。

---

## Q6. ログファイルの読み取りで `Permission denied` になる

**現象**

```bash
sudo journalctl -u log-watch-alert -n 5
```

```text
tail: cannot open '/var/log/app/error.log' for reading: Permission denied
```

**原因**

監視プロセスを実行している`logwatch`ユーザーに、監視対象ログファイルへの読み取り権限が無い。アプリケーション側の出力ユーザー・グループの設定によっては、ログファイルの権限が`600`(所有者のみ)などに絞られていることがある。

**対処法**

```bash
ls -l /var/log/app/error.log
```

```text
-rw------- 1 appuser appuser 1240 Aug 31 09:00 /var/log/app/error.log
```

`logwatch`ユーザーが読めるように、他ユーザーへの読み取り権限を付与する(書き込み権限は不要)。

```bash
sudo chmod o+r /var/log/app/error.log
```

もしくは、`logwatch`ユーザーをログ出力元と同じグループに所属させる方法もある(権限をより絞りたい場合)。

```bash
sudo usermod -aG appuser logwatch
sudo systemctl restart log-watch-alert
```

💡ポイント: このツールはログを**読むだけ**でよいので、書き込み権限まで与える必要はない。必要最小限の権限だけを付与するのがセキュリティの基本([01-requirements.md](./01-requirements.md) NFR-05)。

---

## Q7. サーバー再起動後に、サービスが起動していない

**現象**

サーバーを再起動した後、`systemctl status log-watch-alert`を見ると`inactive (dead)`になっている。

**原因**

`systemctl start`だけを実行し、`systemctl enable`を実行し忘れている。`start`は「今すぐ起動する」だけの指定であり、次回起動時に自動的に立ち上がる設定(`enable`)とは別物。

**対処法**

```bash
systemctl is-enabled log-watch-alert
```

```text
disabled
```

`disabled`と表示された場合は、`enable`し忘れていることが原因。

```bash
sudo systemctl enable log-watch-alert
sudo systemctl start log-watch-alert
systemctl is-enabled log-watch-alert
```

```text
enabled
```

💡ポイント: `start`と`enable`は別のスイッチ。「今動いているか」と「次回以降も自動で動くか」は別々に確認する習慣をつける([02-design.md](./02-design.md) 4.5節参照)。

---

## Q8. 状態ファイル(state.tsv)が壊れているという警告ログが出る

**現象**

`journalctl`に以下のような`[WARN]`ログが記録される。

```text
[2026-08-31 09:10:02] [WARN]  状態ファイルの内容が不正なため、最終通知時刻を初期値(0)として扱います: /var/lib/log-watch-alert/state.tsv
[2026-08-31 09:10:02] [INFO]  Slack通知を送信しました(HTTP 200)
```

**原因**

`/var/lib/log-watch-alert/state.tsv`の中身が、想定している「エポック秒<TAB>抑制件数」という数値2つの形式になっておらず、手動編集や書き込み中の中断(ディスク容量不足等)によって壊れた文字列が入っている。

**対処法**

`log-watch-alert.sh`は、状態ファイルの値が数値として妥当かをチェックし、不正な場合は自動的に初期値(0)へフォールバックしたうえでこの警告ログを出し、処理を継続する設計になっている([02-design.md](./02-design.md) 4.6節参照)。この検証を入れていない実装だと、不正な文字列がそのまま算術式(`$(( ))`)に渡り、`line ...: unbound variable`のようなエラーでプロセスごと異常終了してしまう。

つまり、この`[WARN]`ログが出ること自体は異常終了ではなく、**自動復旧が正しく機能している**証拠であり、通知処理はこのあとも続行される。同じ警告が頻発する場合(何らかの原因で毎回状態ファイルが壊れてしまう場合)は、状態ファイルを削除して作り直すことで復旧できる。

```bash
sudo systemctl stop log-watch-alert
sudo rm -f /var/lib/log-watch-alert/state.tsv
sudo systemctl start log-watch-alert
cat /var/lib/log-watch-alert/state.tsv
```

```text
0	0
```

💡ポイント: 「ファイルが存在しない」場合だけでなく「ファイルの中身がおかしい」場合まで壊れずに動き続けられるかは、実務でも見落とされがちな観点。状態を外部ファイルに持たせる設計をするときは、必ず異常な中身への耐性もあわせて考える。
