# 03. 構築手順書

本手順は、Ubuntu Server 22.04 LTS上に、監視対象となるアプリケーション(架空のWebアプリ)がログを`/var/log/app/error.log`へ出力している状態を前提に進める。手元に実際のアプリが無くても、この手順の中で疑似的なログファイルを作成しながら進められる。

コマンドは基本的に`sudo`権限で実行する想定(実行例では`sudo`を付けている箇所と省略している箇所がある)。

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

## Step 1. 必要なパッケージのインストール

```bash
sudo apt-get update
sudo apt-get install -y curl jq
```

```text
...
The following NEW packages will be installed:
  jq
...
Setting up jq (1.6-2.1ubuntu3) ...
```

**何をしているか**: Slackへの通知に使う`curl`(多くの場合プリインストール済み)と、JSONを安全に組み立てるための`jq`をインストールしている。

**なぜ**: `jq`は標準では入っていないことが多い。入っていない状態で監視スクリプトを起動すると、後述の事前チェック機能によって「コマンドが見つかりません」というエラーで即座に停止する仕様にしている([02-design.md](./02-design.md) 4.4節参照)。

インストールできたか確認する。

```bash
curl --version | head -1
jq --version
```

```text
curl 7.81.0 (x86_64-pc-linux-gnu) libcurl/7.81.0 ...
jq-1.6
```

## Step 2. 監視対象ログファイルの準備

```bash
sudo mkdir -p /var/log/app
sudo touch /var/log/app/error.log
sudo chmod 644 /var/log/app/error.log
```

**何をしているか**: 監視対象となるディレクトリとログファイルを作成している。`chmod 644`により、所有者(root)以外も読み取りだけはできる状態にする。

**なぜ**: 後述の`logwatch`という専用ユーザーが、root権限を持たなくてもこのログファイルを**読む**ことだけはできるようにするため(書き込みは不要なので付与しない=最小権限の原則)。

```bash
ls -l /var/log/app/error.log
```

```text
-rw-r--r-- 1 root root 0 Aug 31 09:00 /var/log/app/error.log
```

💡ポイント: 実際の現場では、このログファイルはアプリケーションのプロセスが書き込む。今回はまだ何も書かれていない空のファイルなので、このあとのステップでダミーのログを追記しながら動作確認していく。

## Step 3. Slack Incoming Webhookの発行

1. 通知を送りたいSlackワークスペースを開き、「App管理」→「Incoming Webhooks」を追加する
2. 通知先チャンネル(例: `#alert-log`)を選択し、Webhook URL(`https://hooks.slack.com/services/...`)を発行する
3. 発行されたURLをコピーしておく(このあとStep 6で設定ファイルに書き込む)

**なぜ**: WebhookはURLさえ知っていればJSONをPOSTするだけでSlackに投稿できる仕組み(=Incoming Webhook)。API認証のトークン管理などが不要で、ポートフォリオとしても再現性が高いため採用している([02-design.md](./02-design.md) 4.3節参照)。

疎通確認だけ先に行いたい場合は、以下を単体で実行する。

```bash
curl -v -X POST -H 'Content-type: application/json' \
    --data '{"text": "疎通テストです"}' \
    "<YOUR_SLACK_WEBHOOK_URL>"
```

```text
> POST /services/... HTTP/1.1
> Content-type: application/json
...
< HTTP/1.1 200 OK
...
ok
```

`ok`という本文とHTTP 200が返ってくれば疎通OK。対象チャンネルに「疎通テストです」と投稿されていることも確認する。

## Step 4. サービス専用ユーザーの作成

```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin logwatch
```

**何をしているか**: `logwatch`という、ログイン不可・ホームディレクトリ不要のシステム専用ユーザーを作成している。

| オプション | 意味 |
|---|---|
| `--system` | システムアカウントとして作成する(通常のログインユーザーと区別される) |
| `--no-create-home` | ホームディレクトリを作らない(このユーザーはSSHログイン等をしないため不要) |
| `--shell /usr/sbin/nologin` | シェルログインをできなくする(サービス実行専用のアカウントであることを明示する) |

**なぜ**: 監視プロセスをroot権限で動かし続けると、万が一スクリプトに脆弱性があった場合の被害が大きくなる。専用の非rootユーザーで実行することで、影響範囲を必要最小限に抑える([01-requirements.md](./01-requirements.md) NFR-05参照)。

```bash
id logwatch
```

```text
uid=997(logwatch) gid=997(logwatch) groups=997(logwatch)
```

## Step 5. 配置先ディレクトリの作成

```bash
sudo mkdir -p /opt/log-watch-alert
sudo mkdir -p /var/lib/log-watch-alert
```

**何をしているか**: スクリプト・設定ファイルの配置先(`/opt/log-watch-alert`)と、状態ファイル(直近通知時刻など)の保存先(`/var/lib/log-watch-alert`)を作成している。

**なぜ**: 「アプリ本体(`/opt`配下)」と「実行中に変化するデータ(`/var/lib`配下)」を分けるのはLinuxの慣習的なディレクトリ設計。あとで権限を分けて管理しやすくなる。

## Step 6. スクリプト・設定ファイルの配置

本リポジトリの`src/`配下のファイルを対象サーバーへ配置する。ここではリポジトリを`scp`でサーバーに送る方法と、内容を直接貼り付ける方法のどちらでもよい。

```bash
sudo cp src/log-watch-alert.sh /opt/log-watch-alert/log-watch-alert.sh
sudo cp src/log-watch-alert.env.example /opt/log-watch-alert/.env
```

**何をしているか**: 本体スクリプトと設定ファイル(サンプルを`.env`という名前でコピー)をそれぞれ配置先へコピーしている。

```bash
sudo chmod 750 /opt/log-watch-alert/log-watch-alert.sh
sudo chmod 600 /opt/log-watch-alert/.env
sudo chown -R logwatch:logwatch /opt/log-watch-alert /var/lib/log-watch-alert
```

**何をしているか**:
- `log-watch-alert.sh`に実行権限を付与しつつ、`750`(所有者は読み書き実行、グループは読み取り実行のみ、その他は不可)に制限する
- `.env`はSlack Webhook URL(秘匿情報)を含むため、所有者のみ読み書き可能な`600`に制限する
- スクリプト・設定・状態ファイルの所有者を、Step 4で作成した`logwatch`ユーザーに変更する

💡ポイント: `chmod 600`を忘れると、サーバーの他の利用者からWebhook URLが読めてしまう。パーミッション設定は「動けばOK」ではなく、セキュリティの観点でも必ずセットで確認する習慣をつける([04-test-plan.md](./04-test-plan.md) TC-14相当)。

**確認**:

```bash
ls -l /opt/log-watch-alert/
```

```text
-rwxr-x--- 1 logwatch logwatch 4820 Aug 31 09:10 log-watch-alert.sh
-rw------- 1 logwatch logwatch  650 Aug 31 09:10 .env
```

`log-watch-alert.sh`は`750`(所有者:読み書き実行、グループ:読み取り実行、その他:権限なし)、`.env`は`600`(所有者のみ読み書き)になっていることを、`ls -l`の左端の権限表示で確認する。数値表記でまとめて確認したい場合は次のコマンドでも見られる。

```bash
stat -c '%a %U:%G %n' /opt/log-watch-alert/log-watch-alert.sh /opt/log-watch-alert/.env
```

```text
750 logwatch:logwatch /opt/log-watch-alert/log-watch-alert.sh
600 logwatch:logwatch /opt/log-watch-alert/.env
```

## Step 7. 設定ファイル(.env)の編集

```bash
sudo vi /opt/log-watch-alert/.env
```

```bash
# 編集前(初期状態はプレースホルダーのまま)
SLACK_WEBHOOK_URL=<YOUR_SLACK_WEBHOOK_URL>

# 編集後: <YOUR_SLACK_WEBHOOK_URL> の部分を、Step 3で発行した
# https://hooks.slack.com/services/ から始まる実際のURLに書き換える
```

他の項目(`LOG_FILE`, `ALERT_PATTERN`, `THROTTLE_SECONDS`, `STATE_DIR`, `HOSTNAME_LABEL`)は既定値のままでよい。今回は`/var/log/app/error.log`を監視する前提なので、`LOG_FILE`はサンプルのままで一致している。

**なぜ**: 設定値(秘匿情報を含む)とロジック(スクリプト本体)を分離することで、Webhook URLが変わっても`log-watch-alert.sh`自体を編集する必要がなくなる([02-design.md](./02-design.md) NFR-06参照)。

## Step 8. 手動実行での動作確認(通常検知)

systemdに登録する前に、まず`logwatch`ユーザーとして手動実行し、正しく動くか確認する。ターミナルを2枚(監視用・ログ追記用)用意すると確認しやすい。

**ターミナルA(監視スクリプトを起動したままにする)**:

```bash
sudo -u logwatch bash -c 'set -a; source /opt/log-watch-alert/.env; set +a; /opt/log-watch-alert/log-watch-alert.sh'
```

```text
[2026-08-31 09:20:11] [INFO]  監視を開始します: /var/log/app/error.log (検知パターン: ERROR|CRITICAL / スロットリング: 300秒)
```

**何をしているか**: `.env`の中身を環境変数として読み込んでから(`set -a`は「以降の変数代入を自動的にexportする」指定)、`logwatch`ユーザー権限でスクリプトを起動している。起動直後は「監視を開始します」というログだけが出て、ターミナルはそのまま待機状態になる(=`tail -F`が新しい行を待ち続けているため、正常な状態)。

**ターミナルB(ログを追記して検知させる)**:

```bash
echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO] 通常のアクセスログです" | sudo tee -a /var/log/app/error.log
echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] DB接続に失敗しました" | sudo tee -a /var/log/app/error.log
```

**ターミナルAに表示されるはずのログ**:

```text
[2026-08-31 09:21:03] [INFO]  Slack通知を送信しました(HTTP 200)
```

💡ポイント: `[INFO] 通常のアクセスログです`という行では何も表示されない(=検知されず無視された)ことを確認する。`[ERROR]`の行を追記した瞬間だけ通知ログが出れば、`grep -E "ERROR|CRITICAL"`によるフィルタリングが正しく機能している証拠になる。

Slackの対象チャンネルにも、以下のような通知が届いていることを確認する。

```text
🚨 ログ異常検知 🚨
ホスト: web01
監視対象: /var/log/app/error.log
検知時刻: 2026-08-31 09:21:03
検知内容(抜粋):
2026-08-31 09:21:03 [ERROR] DB接続に失敗しました
```

## Step 9. スロットリング(通知の集約)の動作確認

本リポジトリの`test-generate-log.sh`を使うと、擬似的な連続エラーを簡単に発生させられる。設定ファイルの`THROTTLE_SECONDS`は既定300秒(5分)だが、確認を早く終わらせたい場合は一時的に短い値(例: 10秒)に変更してもよい。

```bash
# (任意)確認を速くしたい場合、一時的にスロットリング時間を10秒に変更する
sudo sed -i 's/THROTTLE_SECONDS=300/THROTTLE_SECONDS=10/' /opt/log-watch-alert/.env
```

設定変更後は、ターミナルAの監視スクリプトを一度`Ctrl+C`で止め、再度Step 8のコマンドで起動し直す(環境変数を読み直すため)。

**ターミナルBでCRITICALログを短時間に5回連続追記する**:

```bash
LOG_FILE=/var/log/app/error.log sudo -E ./src/test-generate-log.sh CRITICAL 5
```

```text
書き込み完了: /var/log/app/error.log に [CRITICAL] を 5 件追記しました
```

**ターミナルAに表示されるはずのログ**:

```text
[2026-08-31 09:25:40] [INFO]  Slack通知を送信しました(HTTP 200)
[2026-08-31 09:25:40] [INFO]  スロットリング中のため通知を抑制しました(直近通知から0秒 / 抑制件数1)
[2026-08-31 09:25:41] [INFO]  スロットリング中のため通知を抑制しました(直近通知から1秒 / 抑制件数2)
[2026-08-31 09:25:42] [INFO]  スロットリング中のため通知を抑制しました(直近通知から1秒 / 抑制件数3)
[2026-08-31 09:25:42] [INFO]  スロットリング中のため通知を抑制しました(直近通知から1秒 / 抑制件数4)
```

**確認できたこと**: 5回連続で`CRITICAL`が発生しても、Slackへの通知は1回だけ(1回目のみ即時送信、残り4回はスロットリングで抑制)であることが分かる。

さらに、スロットリング時間(10秒)が経過してから、もう1件検知させてみる。

```bash
sleep 12
echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] 再度エラーが発生しました" | sudo tee -a /var/log/app/error.log
```

**ターミナルAに表示されるはずのログ**:

```text
[2026-08-31 09:25:55] [INFO]  Slack通知を送信しました(HTTP 200)
```

Slackに届く通知本文には、抑制していた件数が併記される。

```text
🚨 ログ異常検知 🚨
ホスト: web01
監視対象: /var/log/app/error.log
検知時刻: 2026-08-31 09:25:55
検知内容(抜粋):
2026-08-31 09:25:55 [ERROR] 再度エラーが発生しました
※直近 10 秒以内に、このほか 4 件の検知を抑制しました(スロットリング)
```

確認できたら、スロットリング時間を既定値に戻し、ターミナルAの手動実行は`Ctrl+C`で終了する。

```bash
sudo sed -i 's/THROTTLE_SECONDS=10/THROTTLE_SECONDS=300/' /opt/log-watch-alert/.env
```

## Step 10. systemdユニットファイルの配置

手動実行での動作確認が済んだら、systemdサービスとして常駐させる。

```bash
sudo cp src/log-watch-alert.service /etc/systemd/system/log-watch-alert.service
```

```bash
sudo systemctl daemon-reload
```

**何をしているか**: `daemon-reload`は、新しく追加・変更したユニットファイルをsystemdに再読み込みさせるコマンド。これを忘れると、ファイルを配置しても古い定義のまま扱われてしまう。

## Step 11. サービスの起動と自動起動の有効化

```bash
sudo systemctl start log-watch-alert
sudo systemctl enable log-watch-alert
```

```text
Created symlink /etc/systemd/system/multi-user.target.wants/log-watch-alert.service → /etc/systemd/system/log-watch-alert.service.
```

**何をしているか**:
- `start`は「今すぐサービスを起動する」
- `enable`は「サーバー再起動後も自動的に起動する設定を有効化する」

💡ポイント: `start`だけだと今は動いているが、サーバーを再起動すると起動しない。`enable`だけだと設定は入るが今はまだ動いていない。**両方セットで実行して初めて**「今も動いていて、再起動後も自動的に立ち上がる」状態になる([02-design.md](./02-design.md) 4.5節参照)。

## Step 12. サービスの状態確認

```bash
sudo systemctl status log-watch-alert
```

```text
● log-watch-alert.service - Log Watch Alert - ERROR/CRITICALログ監視とSlack通知
     Loaded: loaded (/etc/systemd/system/log-watch-alert.service; enabled; vendor preset: enabled)
     Active: active (running) since Mon 2026-08-31 09:30:12 UTC; 5s ago
   Main PID: 4821 (log-watch-alert.)
      Tasks: 2 (limit: 4665)
     Memory: 1.2M
        CPU: 12ms
     CGroup: /system.slice/log-watch-alert.service
             ├─4821 /bin/bash /opt/log-watch-alert/log-watch-alert.sh
             └─4823 tail -F -n 0 /var/log/app/error.log
```

**確認ポイント**: `Active: active (running)`であること、`enabled`と表示されていること(自動起動設定が有効な証拠)。

ログは`journalctl`(systemd配下のプロセスのログを見るコマンド)で確認する。

```bash
sudo journalctl -u log-watch-alert -f
```

```text
Aug 31 09:30:12 web01 log-watch-alert.sh[4821]: [2026-08-31 09:30:12] [INFO]  監視を開始します: /var/log/app/error.log (検知パターン: ERROR|CRITICAL / スロットリング: 300秒)
```

別ターミナルからテストログを追記すれば、Step 8・9と同様に検知・通知ログが流れることを確認できる。

```bash
sudo LOG_FILE=/var/log/app/error.log ./src/test-generate-log.sh ERROR 1
```

💡ポイント: `-f`(follow)を付けると`journalctl`もリアルタイムに追尾表示できる。抜けるときは`Ctrl+C`。

## Step 13. サーバー再起動後も自動起動することの確認

実際にサーバーを再起動できる環境であれば、再起動後に以下を確認する。

```bash
sudo reboot
```

再起動後、SSHで再接続してから確認する。

```bash
systemctl is-enabled log-watch-alert
systemctl is-active log-watch-alert
```

```text
enabled
active
```

再起動できない検証環境(コンテナ等)の場合は、代わりにサービスを明示的に停止・起動し直して、`enable`されていることだけを確認してもよい。

```bash
sudo systemctl stop log-watch-alert
sudo systemctl is-active log-watch-alert
```

```text
inactive
```

```bash
sudo systemctl start log-watch-alert
sudo systemctl is-active log-watch-alert
```

```text
active
```

## Step 14. 一括セットアップスクリプト(任意)

Step 4〜Step 11相当の内容は、`src/install.sh`としてもまとめてある。2回目以降の環境構築や、「手作業を自動化する」というこの案件そのもののテーマを体現する例として使える。

```bash
cd src
sudo ./install.sh
```

```text
==> 1/6 サービス専用ユーザーを作成します: logwatch
  -> ユーザー 'logwatch' を作成しました
==> 2/6 インストール先ディレクトリを準備します: /opt/log-watch-alert
==> 3/6 設定ファイル(.env)を準備します
  -> /opt/log-watch-alert/.env を作成しました。SLACK_WEBHOOK_URL 等を編集してください。
==> 4/6 状態ファイル用ディレクトリを作成します: /var/lib/log-watch-alert
==> 5/6 systemdユニットファイルを配置します
==> 6/6 systemdに変更を認識させ、自動起動を有効化します

インストールが完了しました。次の手順を行ってください。
  1. /opt/log-watch-alert/.env を編集し、SLACK_WEBHOOK_URL などを設定する
  2. 監視対象のログファイル(LOG_FILEに指定したパス)が存在することを確認する
  3. sudo systemctl start log-watch-alert
  4. sudo systemctl status log-watch-alert で起動確認する
```

💡ポイント: 学習目的ではStep 4〜11を1つずつ手で実行し、「なぜそのコマンドが必要か」を理解することを優先する。`install.sh`はあくまで「理解した上で自動化する」ことのデモとして位置づける。

## Step 15. 最終確認チェックリスト

| 確認項目 | コマンド | 期待結果 |
|---|---|---|
| jq/curlがインストール済み | `jq --version; curl --version` | それぞれバージョンが表示される |
| スクリプトの実行権限・所有者 | `ls -l /opt/log-watch-alert/log-watch-alert.sh` | 所有者`logwatch`、実行権限あり |
| 設定ファイルの権限 | `stat -c '%a' /opt/log-watch-alert/.env` | `600` |
| サービスが起動している | `systemctl is-active log-watch-alert` | `active` |
| 自動起動が有効 | `systemctl is-enabled log-watch-alert` | `enabled` |
| ERRORログで通知が届く | `test-generate-log.sh ERROR 1` を実行しSlackを確認 | 数秒以内に通知が届く |
| 連続検知がスロットリングされる | `test-generate-log.sh CRITICAL 5` を実行 | 通知は1回のみ届く |
| journalctlでログが追える | `journalctl -u log-watch-alert -n 20` | 起動・検知・通知のログが記録されている |

すべて満たしていれば構築完了。詳細なテストケースは[04-test-plan.md](./04-test-plan.md)を参照。
