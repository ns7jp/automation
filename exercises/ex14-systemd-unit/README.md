# ex14: systemdユニットを書く

| 項目 | 内容 |
|---|---|
| ステージ | 3: ログ監視と常駐化 |
| 難易度 | ★★★☆☆ |
| 目安時間 | 45分 |
| 身につく力 | systemdユニットの3セクション / Type=simple / Restart=always / WantedBy |
| 対応する案件 | [案件No.3 ログ監視・異常検知アラート](../../projects/03-log-monitoring-alert/README.md) |
| 作業するファイル | `work/log-watch-alert.service` |

---

## 1. どんな場面で必要になるか

ex11・ex12・ex13 で作ってきたログ監視スクリプトは、**あなたがターミナルで実行している間しか動きません**。SSH の接続を切れば止まりますし、サーバーが再起動すれば当然止まったままです。「監視しているつもりだったが、実は先週から止まっていた」というのは、運用現場で本当によくある事故です。

そこで、スクリプトを **サーバーの常駐サービスとして登録** します。Ubuntu や RHEL 系など現在の主要な Linux では、この登録先が **systemd** (サーバーの起動処理とサービス管理を担当する仕組み) です。systemd に「このスクリプトをサービスとして扱ってください」と伝えるための設定ファイルを **ユニットファイル** と呼びます。

ユニットファイルを1枚書いておけば、`systemctl start` で起動、`systemctl enable` でサーバー再起動後の自動起動、プロセスが落ちたときの自動再起動、ログの一元管理まで、すべて systemd が面倒を見てくれます。**「常駐させる」という要件を、シェルスクリプト側の工夫ではなく設定ファイルで解決する**のがポイントです。

この演習では、案件No.3 の `log-watch-alert.service` をやさしくした版を、自分の手で書きます。

---

## 2. この演習で学ぶこと

| 学ぶこと | ひとことで言うと |
|---|---|
| `[Unit]` セクション | サービスの説明と「起動順序」を書く場所 |
| `[Service]` セクション | 「何を、どう動かすか」を書く場所。ユニットファイルの本体 |
| `[Install]` セクション | `systemctl enable` したときの扱いを書く場所 |
| `Type=simple` | 起動したプロセスが動き続けること自体をサービスとみなすモード |
| `Restart=always` / `RestartSec` | 落ちたら自動で再起動する。何秒待って再起動するか |
| `EnvironmentFile=-` | 設定ファイルを環境変数として読み込む。`-` は「無くても起動する」 |
| `WantedBy=multi-user.target` | OS起動時の自動起動対象にする指定 |

### 3分でわかる予備知識

**ユニットファイルの形**

ユニットファイルは「セクション見出し」と「キー=値」だけでできた、とても単純なテキストファイルです。

```ini
[Unit]
Description=説明文

[Service]
ExecStart=/opt/scripts/hello.sh

[Install]
WantedBy=multi-user.target
```

- 見出しは `[Unit]` のように**角括弧で囲み、行頭から**書きます (半角の `[` `]` を使います)
- 設定は `キー=値` の形で書きます。**`=` の前後に空白を入れません**
- `#` で始まる行はコメントです
- 大文字と小文字は区別されます。`ExecStart` を `execstart` と書くと認識されません

**3つのセクションの役割**

| セクション | 役割 | よく書くもの |
|---|---|---|
| `[Unit]` | サービスの説明と、他のサービスとの前後関係 | `Description` / `After` / `Wants` |
| `[Service]` | 実際に何を起動して、どう面倒を見るか | `Type` / `ExecStart` / `Restart` / `User` |
| `[Install]` | `systemctl enable` したときに、どこに紐づけるか | `WantedBy` |

**`After=` と `Wants=` の違い**

```ini
After=network-online.target     # 順序: ネットワークが使えるようになった「あとに」起動する
Wants=network-online.target     # 依存: ネットワークを使えるようにする処理も一緒に動かしたい
```

`After` は**順番**だけの指定で、「先にそれを起動してほしい」という意味は含みません。そのため、通常は `Wants` (または強い依存の `Requires`) とセットで書きます。監視サービスは検知したら通知を飛ばすため、ネットワークが使える状態になってから起動したいので、この2行を書きます。

**`Type=simple` とは**

`ExecStart` で起動したプロセスが**フォアグラウンドで動き続けること**を、サービスが動いている状態とみなすモードです。`tail -F` などで動き続ける監視スクリプトはこれに当てはまります。逆に、スクリプト側で自分をバックグラウンドに回してすぐ終了してしまうと、systemd は「サービスが終了した」と判断してしまいます。**systemd に常駐させるスクリプトは、自分でバックグラウンド化しない**と覚えてください。

**`EnvironmentFile=-` の `-`**

```ini
EnvironmentFile=-/etc/default/log-watch-alert
```

`/etc/default/log-watch-alert` に `KEY=VALUE` 形式で書いた内容を、環境変数としてスクリプトに渡します。パスの前に付いている **`-` は「このファイルが無くても、エラーにせず起動する」** という意味です。設定ファイルをまだ置いていない状態でも、スクリプト側の既定値でとりあえず動かせるようになります。

**`WantedBy=multi-user.target`**

`multi-user.target` は「通常のサーバーとして起動し終えた状態」を表す目印です。ここに `WantedBy` で紐づけておくと、`systemctl enable` を実行したときにシンボリックリンクが作られ、**サーバーを再起動しても自動的に立ち上がる**ようになります。この行が無いと `enable` しても何も起こりません。

---

## 3. 課題

`work/log-watch-alert.service` を編集し、次の仕様を満たすユニットファイルを完成させてください。TODO のコメント行は消して、設定を書いてください。

### 仕様

| No. | 条件 | 期待する動作 |
|---|---|---|
| 1 | 雛形の TODO | TODO と書かれたコメント行がファイルに残っていない |
| 2 | `[Unit]` セクション | 行頭から `[Unit]` と書かれている |
| 3 | サービスの説明 | `Description=ログ監視・異常検知アラート通知サービス` |
| 4 | 起動順序 | `After=network-online.target` |
| 5 | 依存 | `Wants=network-online.target` |
| 6 | `[Service]` セクション | 行頭から `[Service]` と書かれている |
| 7 | 起動モード | `Type=simple` |
| 8 | 実行するコマンド | `ExecStart=/opt/scripts/log-watch-alert.sh` (**絶対パス**) |
| 9 | 設定ファイルの読み込み | `EnvironmentFile=-/etc/default/log-watch-alert` (先頭の `-` を含む) |
| 10 | 異常終了時の扱い | `Restart=always` |
| 11 | 再起動までの待ち時間 | `RestartSec=10` |
| 12 | 実行ユーザー | `User=root` |
| 13 | 標準出力の行き先 | `StandardOutput=journal` |
| 14 | 標準エラー出力の行き先 | `StandardError=journal` |
| 15 | `[Install]` セクション | 行頭から `[Install]` と書かれている |
| 16 | 自動起動の紐づけ先 | `WantedBy=multi-user.target` |

### 完成イメージ / 書式

セクションの順序は `[Unit]` → `[Service]` → `[Install]` にしてください。各セクションの中では、上の表の順に書くと読みやすくなります。説明のコメント (`#` で始まる行) は自由に足してかまいません。

```ini
[Unit]
Description=...
After=...
Wants=...

[Service]
Type=...
ExecStart=...
EnvironmentFile=...
Restart=...
RestartSec=...
User=...
StandardOutput=...
StandardError=...

[Install]
WantedBy=...
```

書式で注意する点は次のとおりです。すべて**半角**で書いてください。

- セクション見出しは行頭から `[Unit]` のように書く (先頭に空白を入れない)
- `キー=値` の `=` の前後に空白を入れない (`Type = simple` は誤り)
- 大文字・小文字は表のとおりに書く (`ExecStart` の E と S は大文字)
- `ExecStart` は `/` から始まる絶対パスで書く (`./log-watch-alert.sh` は動かない)
- `EnvironmentFile` の値は `-/etc/...` のように、パスの直前に `-` を付ける

### 実サーバーでの反映手順 (この演習では実行しません)

書いたユニットファイルは、実際のサーバーでは次のように使います。手順そのものが面接でよく聞かれるので、順番を覚えてください。

```bash
# 1. ユニットファイルを所定の場所に置く
sudo cp log-watch-alert.service /etc/systemd/system/

# 2. systemd に「ユニットファイルを読み直して」と伝える(これを忘れると古い定義のまま)
sudo systemctl daemon-reload

# 3. 自動起動を有効にして、今すぐ起動する(--now が「今すぐ起動」の意味)
sudo systemctl enable --now log-watch-alert

# 4. 状態を確認する(active (running) になっていれば成功)
systemctl status log-watch-alert

# 5. サービスが出力したログを見る(-n 30 は直近30行。-f を付けるとリアルタイム追尾)
journalctl -u log-watch-alert -n 30
```

**起動しないときの調べ方**

```bash
# エラーの原因まで含めて表示する。まずこれを読む
journalctl -xeu log-watch-alert

# ユニットファイルの書式そのものを検査する
systemd-analyze verify /etc/systemd/system/log-watch-alert.service
```

`journalctl -xeu <ユニット名>` の `-x` は説明の追加、`-e` は末尾へジャンプ、`-u` は対象ユニットの指定です。**「起動しない」と言う前に、必ずこのコマンドの出力を読む**のが鉄則です。`Restart=always` を書いていると、失敗しても10秒ごとに再起動を繰り返すため、`systemctl status` だけを見ていると「起動中に見えるのに動いていない」という紛らわしい状態になります。

---

## 4. やり方

```bash
# 1. exercises ディレクトリに移動する
cd exercises

# 2. 編集する(エディタは vim でも nano でも VS Code でもよい)
nano ex14-systemd-unit/work/log-watch-alert.service

# 3. 書式を目で確認する(= の前後に空白が入っていないか、行頭に空白が無いか)
cat -A ex14-systemd-unit/work/log-watch-alert.service | head -20

# 4. 採点する
./check.sh 14
```

`cat -A` は行末を `$` で、タブを `^I` で表示するコマンドです。**キーと値の間に余計な空白が入っていないか**を確認するのに使えます。

この演習では、あなたのPCに何かをインストールしたり、サービスを起動したりすることはありません。ファイルの中身だけを採点します。systemd が入っている環境なら、採点の最後に `systemd-analyze verify` による書式検査も行います (入っていない環境ではスキップされます)。

---

## 5. ヒント

自力で15分考えてから開いてください。段階的に答えに近づくよう3段階に分けています。

<details>
<summary>ヒント1: どこに何を書くかの考え方</summary>

迷ったら「その設定は**いつ**効くのか」で仕分けします。

- **起動する前**の話 (説明・順序・依存) → `[Unit]`
- **起動している間**の話 (何を動かす・落ちたらどうする・誰の権限で動かす・ログの行き先) → `[Service]`
- **`systemctl enable` したとき**の話 → `[Install]`

例えば `Restart=always` は「動いている間に落ちたら」の話なので `[Service]`、`WantedBy=` は「有効化したとき」の話なので `[Install]` です。セクションを間違えると、systemd はその設定を**黙って無視します**。エラーが出ないぶん気づきにくいので注意してください。

</details>

<details>
<summary>ヒント2: 書き方の具体例</summary>

`[Unit]` はこう書きます。

```ini
[Unit]
Description=ログ監視・異常検知アラート通知サービス
After=network-online.target
Wants=network-online.target
```

`[Service]` の最初の3行はこうです。

```ini
[Service]
Type=simple
ExecStart=/opt/scripts/log-watch-alert.sh
EnvironmentFile=-/etc/default/log-watch-alert
```

`EnvironmentFile` の値は `-` から始まっている点に注目してください。`-` を書き忘れると、設定ファイルが存在しない環境で**サービスが起動しなくなります**。

</details>

<details>
<summary>ヒント3: 全体の骨組み</summary>

残りは `Restart` / `RestartSec` / `User` / `StandardOutput` / `StandardError` と、`[Install]` セクションです。

```ini
[Unit]
# 説明・順序・依存(ヒント2のとおり)

[Service]
# Type / ExecStart / EnvironmentFile(ヒント2のとおり)

# 落ちたら必ず再起動する。再起動までの待ち時間は10秒
Restart=???
RestartSec=??

# 実行ユーザー
User=????

# 標準出力・標準エラー出力を journald(systemdのログ収集の仕組み)へ送る
StandardOutput=???????
StandardError=???????

[Install]
# systemctl enable したときに、通常起動の一員として登録する
WantedBy=?????????????????
```

値は仕様表の No.10〜16 にそのまま書いてあります。写すだけでなく、**それぞれの値が何を意味するか**を「2. この演習で学ぶこと」で確認しながら書いてください。

</details>

---

## 6. よくあるつまずき

| 症状 | 原因と対処 |
|---|---|
| `Failed to start ...: Unit log-watch-alert.service not found.` | ユニットファイルを `/etc/systemd/system/` に置いていない、またはファイル名が違う。拡張子は `.service` |
| ファイルを直したのに反映されない | `sudo systemctl daemon-reload` を忘れている。ユニットファイルを編集したら毎回必要 |
| `systemctl enable` したのに再起動後に立ち上がらない | `[Install]` セクションと `WantedBy=multi-user.target` を書いていない。`systemctl is-enabled log-watch-alert` で `enabled` になるか確認する |
| `status` が `activating` と `failed` を繰り返す | スクリプト自体が起動直後にエラー終了している。`journalctl -xeu log-watch-alert` でスクリプトのエラーメッセージを読む |
| `Failed to parse ...` と怒られる | `=` の前後に空白を入れた、セクション見出しの前に空白がある、全角の記号を使っているなど。`cat -A` で確認する |
| 設定ファイルが無いだけで起動に失敗する | `EnvironmentFile=` の値の先頭に `-` を付けていない |
| 起動した直後に `inactive (dead)` になる | スクリプトが自分をバックグラウンドに回して終了している。`Type=simple` ではフォアグラウンドで動き続ける必要がある |

`./check.sh 14` が失敗したときは、**「期待」と「実際」の差分**を必ず読んでください。どの行が足りないかがそのまま書かれています。

---

## 7. 発展課題(採点対象外)

余裕がある人向けの追加課題です。実務では「もう一歩の気配り」が評価されます。

1. `User=root` をやめ、専用ユーザー `logwatch` で動かす形に書き換える (ログファイルの読み取り権限をどう与えるかまで考える)
2. `NoNewPrivileges=true` と `ProtectSystem=strict` を追加し、それぞれが何を制限するのか調べて自分の言葉でコメントに書く (案件No.3 の実物が参考になります)
3. `Restart=always` を `Restart=on-failure` に変えると挙動がどう変わるか、`StartLimitBurst` と合わせて調べる (「再起動を繰り返して CPU を食い潰す」事故の防ぎ方)

---

## 8. この演習と案件のつながり

案件No.3 の常駐化そのものが、この演習に対応しています。

- 3セクション構成と各ディレクティブの意味 → [`log-watch-alert.service`](../../projects/03-log-monitoring-alert/src/log-watch-alert.service)
- `EnvironmentFile=` で設定を外出しする考え方 → 同案件の [`log-watch-alert.env.example`](../../projects/03-log-monitoring-alert/src/log-watch-alert.env.example)
- `daemon-reload` → `enable --now` → `status` → `journalctl` の運用手順 → 同案件の [03-build-guide.md](../../projects/03-log-monitoring-alert/03-build-guide.md)
- 起動しないときの切り分け → 同案件の [05-troubleshooting.md](../../projects/03-log-monitoring-alert/05-troubleshooting.md)
- 案件の実物では、この演習に加えて専用ユーザーでの実行 (`User=logwatch`) とセキュリティ強化オプションが入っています。演習で骨格を理解してから読むと、追加分の意味がはっきり分かります

次は [ex15: 複数台をまとめて監視する](../ex15-multi-target-check/README.md) に進んでください。
