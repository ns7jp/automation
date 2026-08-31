# 05. トラブルシューティング集

構築・運用中によく遭遇するトラブルをQ&A形式でまとめる。

---

## Q1. pushしてもワークフローが1つも実行されない(Actionsタブに履歴すら出ない)

**現象**

```bash
git push origin main
```

pushは成功するが、GitHubリポジトリの「Actions」タブを見ても、新しい実行履歴が1件も追加されない。

**原因(よくあるもの)**

| 原因 | 確認方法 |
|---|---|
| ワークフローファイルの配置場所が違う(`.github/workflows/`以外に置いている) | `git show --stat HEAD` でコミットに含まれるファイルパスを確認 |
| ワークフローファイルの拡張子が`.yml`/`.yaml`以外になっている | `ls .github/workflows/` |
| `on.push.branches`の指定と、実際にpushしたブランチ名が一致していない(例: `master`にpushしたのに`branches: [main]`になっている) | `git branch --show-current` で今のブランチ名を確認 |
| YAML自体に構文エラーがあり、GitHubがワークフローとして認識できていない | 後述のQ7を参照 |

**対処法**

```bash
# 配置場所と拡張子を確認する
find . -path "*/workflows/*"
```

```text
./.github/workflows/deploy.yml
```

正しいパス(`.github/workflows/`直下、拡張子`.yml`)に置かれているか、`on.push.branches`が実際のブランチ名と一致しているかを見直す。

💡ポイント: 「動くはずのYAMLを書いたのに何も起きない」場合、ほぼ確実に**トリガーの条件に一致していない**ことが原因。焦って処理の中身(jobs以下)を疑う前に、まず`on`の設定と、実際に行った操作(どのブランチにpushしたか等)を照らし合わせる癖をつけると、原因特定が早くなる。

---

## Q2. `Permission denied (publickey)` と表示され、SSH認証に失敗する

**現象**

```text
deploy@192.168.1.30: Permission denied (publickey).
rsync: connection unexpectedly closed (0 bytes received so far) [sender]
rsync error: unexplained error (code 255) at io.c(...) [sender=3.2.7]
```

**原因(よくあるもの)**

| 原因 | 確認方法 |
|---|---|
| 公開鍵がサーバーの`authorized_keys`に登録されていない、または登録した公開鍵と使っている秘密鍵の組み合わせが違う | サーバー上で`cat /home/deploy/.ssh/authorized_keys`を確認し、`deploy_key.pub`の内容と一致するか比較 |
| `GitHub Secrets`の`DEPLOY_SSH_KEY`に、秘密鍵の中身を正しく登録できていない(改行が壊れている・余分な空白が入っている) | Secretsは値を再表示できないため、疑わしい場合は`gh secret set DEPLOY_SSH_KEY < ./deploy_key`で登録し直す(03-build-guide.md Step 8参照) |
| `~/.ssh`や`authorized_keys`のパーミッションが緩すぎる | サーバー上で`ls -ld /home/deploy/.ssh /home/deploy/.ssh/authorized_keys`を確認 |
| 接続ユーザー名(`DEPLOY_USER`)が違う | Secretsの値とサーバー上に実在するユーザー名を照合 |

**対処法**

パーミッションを疑う場合は、サーバー上で以下を確認・修正する。

```bash
ls -ld /home/deploy/.ssh /home/deploy/.ssh/authorized_keys
```

```text
drwx------ 2 deploy deploy 4096 Aug 31 09:10 /home/deploy/.ssh
-rw------- 1 deploy deploy  103 Aug 31 09:10 /home/deploy/.ssh/authorized_keys
```

`drwx------`(700)・`-rw-------`(600)以外になっている場合は、OpenSSHが「他人が書き換えられる可能性のあるファイルは信用しない」という安全側の判断で認証を拒否する。

```bash
sudo -u deploy chmod 700 /home/deploy/.ssh
sudo -u deploy chmod 600 /home/deploy/.ssh/authorized_keys
```

💡ポイント: SSH認証のトラブルは「鍵そのものの問題」と「権限(パーミッション)の問題」の2系統に分けて切り分けると原因を見つけやすい。まずは手元(CIではなく自分のPC)から同じ秘密鍵で接続できるかを試す([03-build-guide.md](./03-build-guide.md) Step 4のように)と、GitHub Actions特有の問題なのか、鍵・サーバー設定自体の問題なのかを切り分けられる。

---

## Q3. `Host key verification failed` と表示される

**現象**

```text
Host key verification failed.
rsync: connection unexpectedly closed (0 bytes received so far) [sender]
rsync error: unexplained error (code 255) at io.c(...) [sender=3.2.7]
```

**原因**

SSHクライアントが「接続先サーバーの正体を確認できない」と判断し、接続を拒否している。通常、初回接続時に`known_hosts`へサーバーの鍵を登録することでこの確認が完了するが、GitHub Actionsのランナーは毎回まっさらな環境(使い捨て)のため、`known_hosts`に何も登録されていない状態から始まる。

`scripts/deploy.sh`では、この問題を避けるため`-o StrictHostKeyChecking=accept-new`という設定を使っている。にもかかわらずこのエラーが出る場合、以下のいずれかが疑われる。

| 原因 | 確認方法 |
|---|---|
| `deploy.sh`の`-o StrictHostKeyChecking=accept-new`が、何らかの理由で書き換わっている・抜けている | `grep StrictHostKeyChecking scripts/deploy.sh` |
| サーバー側のホスト鍵自体が変わった(サーバーを再構築した、IPアドレスを使い回している等) | `ssh-keyscan -p 22 192.168.1.30` を手元で実行し、サーバーの鍵を再取得できるか確認 |

**対処法**

```bash
grep StrictHostKeyChecking scripts/deploy.sh
```

```text
  -e "ssh -i ${DEPLOY_SSH_KEY} -p ${DEPLOY_PORT} -o StrictHostKeyChecking=accept-new" \
```

この行が存在することを確認する。存在するのにエラーが出る場合は、サーバー側の鍵が変わった可能性が高いため、サーバーを再構築した場合はそれが原因と考えてよい(`accept-new`は「初回のみ自動登録」する設定であり、CI環境はジョブのたびに`known_hosts`がリセットされるため、通常は問題にならない)。

💡ポイント: より高いセキュリティを求める場合、`accept-new`(初回は無条件で信頼する)ではなく、事前に`ssh-keyscan`で取得したサーバーの正しい鍵をGitHub Secretsに保存しておき、ワークフロー内で`known_hosts`に配置してから接続する方法もある。これなら「間に第三者が割り込んで通信を盗み見る攻撃(中間者攻撃)」への耐性が上がる。今回は検証環境の再現のしやすさを優先して`accept-new`を採用しているが、本番運用での発展的な改善ポイントとして覚えておくとよい([02-design.md](./02-design.md) 7章)。

---

## Q4. `rsync: Permission denied` でデプロイに失敗する

**現象**

```text
rsync: [receiver] mkstemp "/var/www/sample-app/.index.html.XXXXXX" failed: Permission denied (13)
rsync error: some files/attrs were not transferred (see previous errors) (code 23) at main.c(...) [sender=3.2.7]
```

**原因**

SSH接続自体は成功しているが、接続先ユーザー(`deploy`)に、転送先ディレクトリへの**書き込み権限が無い**。

**対処法**

```bash
ls -ld /var/www/sample-app
```

```text
drwxr-xr-x 2 root root 4096 Aug 31 09:00 /var/www/sample-app
```

所有者が`root`のままになっている(=`deploy`ユーザーには書き込み権限が無い)ことが分かる。[03-build-guide.md](./03-build-guide.md) Step 1の通り、所有者を`deploy`に変更する。

```bash
sudo chown -R deploy:deploy /var/www/sample-app
```

```bash
ls -ld /var/www/sample-app
```

```text
drwxr-xr-x 2 deploy deploy 4096 Aug 31 09:12 /var/www/sample-app
```

💡ポイント: 「SSH接続はできるのにファイル転送だけ失敗する」場合は、認証(誰か)の問題ではなく、認可(何をしてよいか)の問題であることが多い。エラーメッセージに`Permission denied`と出た時点で、「接続先ユーザーが、対象ディレクトリに対してどんな権限を持っているか」を最初に疑うとよい。

---

## Q5. ローカルではshellcheckが通るのに、CI(GitHub Actions)上でだけ失敗する

**現象**

```bash
# 手元での実行
shellcheck scripts/*.sh
echo $?
```

```text
0
```

手元では問題無いのに、GitHub Actions上の`Run ShellCheck on shell scripts`ステップだけが失敗する。

**原因(よくあるもの)**

| 原因 | 確認方法 |
|---|---|
| ローカルとCIでshellcheckのバージョンが異なり、検出されるルールが増減している | 手元で`shellcheck --version`を確認し、CIログの冒頭に表示されるバージョンと比較 |
| 手元では一部のファイルにしか実行しておらず、CIは`scripts/`配下の全`.sh`ファイルを対象にしている | `find scripts -name "*.sh"`で対象ファイル一覧を確認し、全ファイルに対して手元でも実行し直す |
| pushし忘れているローカルの変更がある(手元の状態とリポジトリの状態がズレている) | `git status`・`git diff`で未commit・未pushの変更が無いか確認 |

**対処法**

CIと全く同じ範囲・同じコマンドで手元でも実行し、条件を揃える。

```bash
find scripts -type f -name "*.sh" -print0 | xargs -0 shellcheck
```

このコマンドと`.github/workflows/deploy.yml`内の`Run ShellCheck on shell scripts`ステップの内容が一致しているかを見比べる。

💡ポイント: 「手元では通るのにCIでは落ちる」系のトラブルは、突き詰めると大半が**手元とCIで実行している条件(バージョン・対象範囲・コミットの状態)が違う**ことに起因する。「同じコマンドを、同じ対象に対して実行しているか」を最初に確認する習慣が、原因調査の時間を大きく縮める。

---

## Q6. Slackに通知が届かない(デプロイ自体は成功しているのに)

**現象**

`deploy`ジョブはすべて✓(成功)なのに、Slackに何も投稿されない。

**原因**

| 原因 | 確認方法 |
|---|---|
| `SLACK_WEBHOOK_URL`のSecretsが未登録、または無効なURLになっている | `gh secret list`で登録済みか確認(値そのものは再表示できないため、疑わしい場合は再登録する) |
| Slack側でIncoming Webhookが無効化・削除されている | Slackの「App管理」画面で、対象のWebhookがまだ有効か確認 |
| Webhook URLの前後に余分な空白・改行が混入している | `gh secret set SLACK_WEBHOOK_URL --body "https://hooks.slack.com/..."`で1行の値として登録し直す |

**対処法**

`curl`単体でSlackへの疎通を確認する。

```bash
curl -v -X POST -H 'Content-type: application/json' \
    --data '{"text": "疎通テスト"}' \
    "<YOUR_SLACK_WEBHOOK_URL>"
```

```text
< HTTP/1.1 200 OK
ok
```

`ok`が返ってくれば疎通は正常。それでもワークフロー経由では届かない場合は、Secretsに登録した値が実際のURLと一致しているかを再確認する。

💡ポイント: `deploy.yml`の通知ステップは`curl -s`(サイレントモード)のみを指定しており、`-f`(HTTPエラー時に失敗扱いにするオプション)は付けていない。そのため、Webhook URLが無効でSlackへの投稿自体が失敗しても、**通知ステップはGitHub Actions上では「成功」のまま**になる([04-test-plan.md](./04-test-plan.md) TC-17)。これは「通知の失敗によってデプロイ結果の記録(ジョブの成否)まで乱れてほしくない」という意図的な設計だが、裏を返すと「通知が届かないこと自体には気づきにくい」というトレードオフでもある。定期的にSlack側の疎通確認を行う、通知ステップにも`-f`を付けて明示的に失敗させる、といった運用でカバーする。

---

## Q7. ワークフローが実行されず「Invalid workflow file」と表示される

**現象**

GitHubのActionsタブに、以下のようなメッセージが表示され、ワークフローがそもそも実行されない。

```text
This run likely failed because of a workflow file issue.

deploy.yml
Invalid workflow file: .github/workflows/deploy.yml#L45
You have an error in your yaml syntax on line 45
```

**原因**

YAMLファイルのインデント(字下げ)の崩れや、コロン`:`の付け忘れなど、**YAMLとしての構文自体が壊れている**。GitHub ActionsはYAMLとして解釈できないファイルを、ジョブの失敗としてではなく「ワークフローの読み込みエラー」として扱う(そのため`test`・`deploy`いずれのジョブも実行履歴に現れない)。

**対処法**

エディタのYAML構文チェック機能や、`python3`の`yaml`モジュールなどでローカルに構文だけでも検証してから push すると早期に気づける。

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/deploy.yml'))" && echo "YAML構文OK"
```

```text
YAML構文OK
```

構文エラーがある場合は、Pythonの例外メッセージに問題箇所(行・列)が表示されるので、それを手がかりに該当行のインデントを見直す。

💡ポイント: YAMLはインデントの深さで階層構造を表現する言語のため、タブとスペースが混在していたり、スペースの数が1つずれていたりするだけで解釈が変わってしまう。エディタの設定で「タブをスペースに自動変換する」「インデントのガイド線を表示する」を有効にしておくと、この種のミスをかなり防げる。

---

## Q8. デプロイは成功しているのに、ブラウザで見ると古い内容のまま表示される

**現象**

`deploy-info.txt`を`curl`で確認すると最新のコミットハッシュになっているのに、ブラウザでサイトを開くと更新前の見た目のまま。

**原因**

多くの場合、サーバー側の問題ではなく**ブラウザのキャッシュ**が原因。ブラウザは一度読み込んだHTML/CSSを一定時間再利用する仕組みを持っており、開発中は更新のたびに古い表示のままになりやすい。

**対処法**

```bash
# キャッシュを使わずに再取得して比較する(ブラウザ側の切り分け)
curl -s http://192.168.1.30/ | grep "<h1>"
```

`curl`で取得した内容が最新であれば、サーバー側は正しく更新されている。ブラウザ側でスーパーリロード(Windows/Linux: `Ctrl+Shift+R`、macOS: `Cmd+Shift+R`)を行うか、シークレットウィンドウで開き直して再確認する。

💡ポイント: 「サーバー側の確認」と「ブラウザに表示されている内容」は別物として扱う。`curl`のようにキャッシュを介さないコマンドで直接確認する習慣をつけておくと、「デプロイの問題」なのか「表示側(キャッシュ)の問題」なのかを素早く切り分けられる。
