# 05. トラブルシューティング集

構築・運用中によく遭遇するトラブルをQ&A形式でまとめる。

---

## Q1. 手動実行では成功するのに、cron経由だと失敗する

**現象**

```bash
sudo /opt/server-health-check/health_check.sh   # これは成功する
```

しかしcronから自動実行されたときだけ、`cron.log`に以下のようなエラーが残る。

```text
/opt/server-health-check/health_check.sh: line 90: ping: command not found
```

**原因**

`cron`は、ログインシェル(SSHでログインしたときのシェル)とは異なり、`PATH`環境変数が最小限しか設定されていない状態でコマンドを実行する。そのため、`.bashrc`などで独自にPATHを拡張している場合、cron実行時にはそのPATHが反映されず、`ping`や`curl`などのコマンドが見つからないことがある。

**対処法**

1. 該当コマンドがどこにあるか確認する

   ```bash
   which ping curl
   ```

   ```text
   /usr/bin/ping
   /usr/bin/curl
   ```

2. 通常は`/usr/bin`や`/bin`は標準のcron PATHに含まれているため、この問題は「独自にインストールしたツールを使っている場合」に起きやすい。発生した場合は、crontab内でPATHを明示的に指定する。

   ```text
   PATH=/usr/local/bin:/usr/bin:/bin
   */5 * * * * /opt/server-health-check/health_check.sh >> /var/log/server-health-check/cron.log 2>&1
   ```

💡ポイント: 「手元では動くのにcronだと動かない」は初心者がほぼ必ず一度は経験するcron特有のハマりどころ。原因の多くはPATHか、カレントディレクトリの違い(cronの作業ディレクトリは実行ユーザーのホームディレクトリになる)にある。

---

## Q2. `ping: command not found` や `ping: socket: Operation not permitted` と表示される

**現象その1**

```bash
sudo /opt/server-health-check/health_check.sh
```

```text
bash: ping: command not found
```

**現象その2**(Dockerコンテナなど一部の制限された環境)

```text
ping: socket: Operation not permitted
```

**原因**

- 現象その1: `ping`コマンド自体(`iputils-ping`パッケージ)がインストールされていない。最小構成のUbuntuイメージやDockerコンテナでは、`ping`が最初から入っていないことがある
- 現象その2: `ping`はICMPパケットを直接組み立てて送るため、通常のTCP/UDP通信よりも高い権限(rootまたは`CAP_NET_RAW`という特権)が必要になる。コンテナ環境などでこの権限が制限されていると、コマンド自体はあってもエラーになる

**対処法**

```bash
# iputils-pingが入っていない場合はインストールする
sudo apt update && sudo apt install -y iputils-ping

# 権限不足の場合、Dockerであれば起動時に権限を付与する
docker run --cap-add=NET_RAW ...
```

💡ポイント: 通常のUbuntu Server(物理サーバーやVM)であれば`iputils-ping`は標準で入っており、`ping`はrootでなくても実行できるよう設定されている。この問題に遭遇するのは主に「最小構成のコンテナで検証している場合」なので、検証環境がどちらのタイプかを意識しておくと原因の切り分けが早くなる。

---

## Q3. HTTP監視の結果が常に`000`になる(サーバーが動いているはずなのに)

**現象**

```bash
curl -o /dev/null -s -w '%{http_code}' --max-time 5 http://web01.example.com/
```

```text
000
```

期待していた`200`ではなく`000`という、実在しないコードが返ってくる。

**原因**

`%{http_code}`が`000`になるのは、**HTTPレスポンスをそもそも受け取れなかった**ことを意味する。よくある原因は次の通り。

| 原因 | 確認方法 |
|---|---|
| ホスト名の名前解決ができない(DNS設定ミス・タイプミス) | `curl -v` で `Could not resolve host` が出ていないか確認 |
| ポート番号の指定漏れ・誤り(例: `8080`番で動いているのに指定していない) | サーバー側で実際に使っているポートを`ss -ltnp`等で確認 |
| ファイアウォールで通信が遮断されている | 監視サーバー→対象サーバー間で該当ポートへの疎通を`curl -v`や`nc -zv`で確認 |
| `--max-time`の秒数以内に応答が返らない(応答が遅すぎる) | `--max-time`を一時的に長くして再実行し、単純な遅延かどうか切り分ける |

**対処法**

まず`-v`(verbose)オプションを付けて、どの段階で失敗しているかを確認する。

```bash
curl -v -o /dev/null -s --max-time 5 http://this-host-does-not-exist.example/
```

```text
* Could not resolve host: this-host-does-not-exist.example
* Closing connection
```

「名前解決」「接続」「応答待ち」のどの段階で止まっているかがログから分かるので、それぞれの原因(DNS/ポート/ファイアウォール/応答遅延)を順に確認していく。

---

## Q4. 連続でNGになっているはずなのに、Slack通知が来ない

**現象**

`state.csv`を見ると連続失敗回数が閾値(`FAIL_THRESHOLD`)を超えているのに、Slackに通知が届かない。

**原因(よくあるもの)**

| 原因 | 確認方法 |
|---|---|
| `ENABLE_SLACK_NOTIFY`が`false`になっている | `health_check.conf`を確認 |
| Webhook URLの入力ミス(コピー漏れ・余分な空白) | `health_check.conf`の`SLACK_WEBHOOK_URL`を目視確認 |
| すでに通知済み(`notified=yes`)の状態が続いている | `state.csv`を確認。「異常検知」は状態が変化した瞬間にしか送られない仕様のため、閾値を超え続けている間は再送されない(意図通りの動作。[02-design.md](./02-design.md) 4.3節参照) |
| サーバーからインターネットへ外部通信できない(プロキシ・ファイアウォール制限) | 下記のcurl単体テストで疎通確認 |

**対処法**

まず`curl`単体でSlackへの疎通を確認する。

```bash
curl -v -X POST -H 'Content-type: application/json' \
    --data '{"text": "疎通テスト"}' \
    "$(grep SLACK_WEBHOOK_URL /opt/server-health-check/health_check.conf | cut -d'"' -f2)"
```

```text
* Connected to hooks.slack.com (xxx.xxx.xxx.xxx) port 443
> POST /services/... HTTP/1.1
< HTTP/1.1 200 OK
ok
```

`ok`が返ってくれば疎通は問題ない。「通知済みのため再送されない」だけなのか、「そもそも送信自体に失敗している」のかを、この2ステップで切り分ける。

---

## Q5. targets.confを編集したら、一部のHTTP監視が急に全部NGになった

**現象**

`targets.conf`をWindowsのメモ帳などで編集して保存したところ、それまで正常だったHTTP監視の対象が、すべて`NG`と判定されるようになった。ping監視の対象には影響が無い。

**原因**

Windows環境のテキストエディタは、改行コードとして`CRLF`(`\r\n`)を使うことが多い。一方Linuxの改行コードは`LF`(`\n`)のみが標準。`targets.conf`が`CRLF`で保存されていると、各行の**最後のフィールド**(`http`行なら期待ステータスコードの`option`列)の末尾に、目には見えない`\r`という文字が紛れ込んでしまう。

その結果、スクリプト内部では`expected_code`の値が`"200"`ではなく`"200\r"`という(表示上は同じに見える)別の文字列になり、`curl`が返す本物の`"200"`と一致しなくなってしまう。

**確認方法**

```bash
cat -A targets.conf | head -n 3
```

```text
web01,http,http://192.168.1.11/,200^M$
web02,http,https://192.168.1.12/,200^M$
```

行末に`^M`という表示があれば、それが`\r`(CR)の目印。`cat -A`は改行コードなど通常は見えない特殊文字を可視化するオプション付きの`cat`実行方法。

**対処法**

```bash
# dos2unixコマンドで改行コードをLFに統一する(未インストールならapt installで導入)
sudo apt install -y dos2unix
dos2unix /opt/server-health-check/targets.conf

# dos2unixが使えない場合はsedでも変換できる
sed -i 's/\r$//' /opt/server-health-check/targets.conf
```

💡ポイント: 設定ファイルはできるだけLinuxサーバー上で直接`vi`/`nano`などのエディタを使って編集するか、Windowsで編集する場合はエディタの改行コード設定を明示的に`LF`にしておくと、このトラブルを未然に防げる。

---

## Q6. macOSなど別のOSで動作確認しようとすると、稼働率が正しく計算されない

**現象**

Ubuntu以外の環境(macOSなど)で`health_check.sh`を試したところ、以下のようなエラーが出て`report.md`の稼働率列が空欄や`N/A`のままになる。

```text
date: illegal option -- d
usage: date [-jnu] [-I[date|hours|minutes|seconds]] [-r seconds] ...
```

**原因**

本ツールは`date -d "-24 hours" '+%Y-%m-%d %H:%M:%S'`のように、GNU版`date`コマンド(GNU coreutils)の`-d`オプション(相対的な日時指定)を利用している。macOS標準の`date`はBSD系という別系統の実装で、オプションの体系が異なり、`-d`ではなく`-v`を使う(例: `date -v-24H`)ため、そのままでは動作しない。

**対処法**

- 本番運用・検証は、要件定義通りUbuntu Server 22.04 LTS(GNU/Linux環境)上で行う
- どうしてもmacOS上で試したい場合は、Homebrewで`coreutils`を導入し、`gdate`(GNU版の`date`)を使うようにスクリプトを読み替える

```bash
brew install coreutils
gdate -d "-24 hours" '+%Y-%m-%d %H:%M:%S'
```

💡ポイント: 同じ「`date`コマンド」という名前でも、GNU版とBSD版でオプションの意味・書式が異なるという点は、シェルスクリプトを書くときに意外と見落としがちな落とし穴。「どのOS・どの実装を前提に書かれたスクリプトか」を常に意識する習慣をつけると、こうした移植性の問題に早く気づけるようになる。

---

## Q7. `health_check.sh`を実行すると`Permission denied`と表示される

**現象**

```bash
/opt/server-health-check/health_check.sh
```

```text
-bash: /opt/server-health-check/health_check.sh: Permission denied
```

**原因**

スクリプトファイルに実行権限(`x`)が付与されていない。

**対処法**

```bash
ls -l /opt/server-health-check/health_check.sh
```

```text
-rw-r--r-- 1 root root 9840 Aug 31 09:00 health_check.sh
```

`x`が無いことを確認したら、実行権限を付与する。

```bash
sudo chmod +x /opt/server-health-check/health_check.sh
```

💡ポイント: 権限が無くても`bash /opt/server-health-check/health_check.sh`のように、明示的にインタプリタ経由で実行すれば動作はする。ただし、cronから安定して実行するためにも`chmod +x`(実質`755`)はきちんと行っておく。
