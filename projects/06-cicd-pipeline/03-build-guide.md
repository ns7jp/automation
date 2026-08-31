# 03. 構築手順書

本手順は、以下の2つを用意する想定で進める。

- **デプロイ先サーバー**: Ubuntu Server 22.04 LTSのVM(検証用サーバー1台で構わない)
- **GitHubリポジトリ**: 新規作成、または既存のリポジトリ(このポートフォリオのリポジトリとは別に、動作確認用のリポジトリを1つ用意する想定)

作業は大きく「① デプロイ先サーバーの受け入れ準備」「② GitHub側の設定」「③ pushして動作確認」の3段階で進める。

## Step 0. 前提の確認

作業用PC(またはCI構築担当者の手元環境)に、必要なコマンドが揃っているか確認する。

```bash
git --version
ssh -V
shellcheck --version
```

```text
git version 2.43.0
OpenSSH_9.6p1, OpenSSL 3.0.13 25 Mar 2024
ShellCheck - v0.9.0
```

**何をしているか**: [01-requirements.md](./01-requirements.md)の検証環境とズレがないかを確認している。

💡ポイント: `shellcheck`が入っていない場合は`sudo apt install -y shellcheck`でインストールできる。GitHub Actions上のジョブは自前でインストールするため必須ではないが、pushする前に手元で確認できると開発がスムーズになる。

GitHub CLI(`gh`)を使うと、後の手順(Step 11)でワークフローの実行状況をターミナルから確認できて便利なので、任意でインストールしておく。

```bash
gh --version
```

```text
gh version 2.63.0 (2026-XX-XX)
```

未インストールの場合は[GitHub公式のインストール手順](https://cli.github.com/)に従う(本手順では無くても最後まで進められる。無い場合はブラウザでActions画面を確認する)。

## Step 1. デプロイ先サーバーの準備

デプロイ専用のSSHユーザーと、Webアプリの公開ディレクトリを用意する。

```bash
# デプロイ専用ユーザーを作成(ログインシェルは通常のbashでよい)
sudo useradd -m -s /bin/bash deploy

# 公開ディレクトリを作成し、deployユーザーの所有にする
sudo mkdir -p /var/www/sample-app
sudo chown -R deploy:deploy /var/www/sample-app

# nginxをインストールする(ファイルを配信するためのWebサーバー)
sudo apt update
sudo apt install -y nginx rsync
```

**何をしているか**: 「デプロイ専用のユーザー」を分けて作成しているのは、CIから接続する権限を必要最小限(このディレクトリへの書き込みだけ)に絞るため。rootユーザーで直接デプロイする設計にもできるが、万が一CI側の鍵が漏えいした場合の被害範囲を小さく抑えられる。

**確認**:

```bash
id deploy
ls -ld /var/www/sample-app
```

```text
uid=1001(deploy) gid=1001(deploy) groups=1001(deploy)
drwxr-xr-x 2 deploy deploy 4096 Aug 31 09:00 /var/www/sample-app
```

nginxの設定(公開ディレクトリを`/var/www/sample-app`に向ける設定)は本案件のスコープ外だが、最小限の動作確認用として以下のように設定しておく。

```bash
sudo tee /etc/nginx/sites-available/sample-app > /dev/null <<'EOF'
server {
    listen 80;
    server_name _;
    root /var/www/sample-app;
    index index.html;
}
EOF

sudo ln -sf /etc/nginx/sites-available/sample-app /etc/nginx/sites-enabled/sample-app
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
```

```text
nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
nginx: configuration file /etc/nginx/nginx.conf test is successful
```

💡ポイント: `nginx -t`は設定ファイルの文法チェックだけを行うオプション(実際には反映しない)。`reload`の前に必ず`-t`で確認する習慣をつけておくと、設定ミスでnginxそのものを落としてしまう事故を防げる。

## Step 2. SSH鍵ペアの生成(CI専用)

GitHub Actionsからの接続専用に、新しいSSH鍵ペアを作る。**個人のログイン用鍵とは必ず分ける**(理由は後述)。

```bash
ssh-keygen -t ed25519 -C "github-actions-deploy" -f ./deploy_key -N ""
```

```text
Generating public/private ed25519 key pair.
Your identification has been saved in ./deploy_key
Your public key has been saved in ./deploy_key.pub
The key fingerprint is:
SHA256:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx github-actions-deploy
```

**何をしているか**:

| オプション | 意味 |
|---|---|
| `-t ed25519` | 鍵の方式にEd25519(比較的新しく、鍵長が短くても安全性が高い方式)を指定する |
| `-C "コメント"` | 鍵に付けるコメント。「どの用途の鍵か」が後から分かるようにする |
| `-f ./deploy_key` | 保存するファイル名(秘密鍵は`deploy_key`、公開鍵は`deploy_key.pub`として保存される) |
| `-N ""` | パスフレーズ(鍵自体を使うときの追加パスワード)を空にする。CIのように人が対話的に入力できない自動処理では、パスフレーズ付きの鍵は使えないため |

💡ポイント: なぜ個人の鍵(`~/.ssh/id_ed25519`など)を使い回さないのか。CI専用の鍵を分けておけば、**この鍵をGitHub Secretsから削除・失効させても、個人の他の作業には一切影響しない**。逆に個人の鍵を使い回してしまうと、CIの鍵を無効化したいだけなのに自分のSSHアクセスまで失う、という事態になりかねない。「用途ごとに鍵を分ける」のは、実務でのSSH鍵運用の基本原則。

## Step 3. 公開鍵をデプロイ先サーバーに登録

生成した公開鍵(`deploy_key.pub`)の中身を、デプロイ先サーバーの`deploy`ユーザーの`authorized_keys`に登録する。

```bash
cat deploy_key.pub
```

```text
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx github-actions-deploy
```

デプロイ先サーバー上で以下を実行する(表示された公開鍵の内容をそのまま貼り付ける)。

```bash
sudo -u deploy mkdir -p /home/deploy/.ssh
sudo -u deploy tee -a /home/deploy/.ssh/authorized_keys <<'EOF'
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx github-actions-deploy
EOF

sudo -u deploy chmod 700 /home/deploy/.ssh
sudo -u deploy chmod 600 /home/deploy/.ssh/authorized_keys
```

**何をしているか**: `authorized_keys`は「この公開鍵に対応する秘密鍵を持っている人(今回はGitHub Actions)からのSSH接続を許可する」というリストファイル。

💡ポイント: `.ssh`ディレクトリは`700`(所有者のみ読み書き実行可)、`authorized_keys`は`600`(所有者のみ読み書き可)にしないと、OpenSSHが「権限が緩すぎる」と判断して**公開鍵認証自体を拒否する**ことがある。パーミッションミスは、SSH接続がうまくいかないときの定番の原因の1つ([05-troubleshooting.md](./05-troubleshooting.md) Q2参照)。

## Step 4. 秘密鍵でのSSH接続確認

GitHub Actionsに登録する前に、生成した鍵で実際に接続できるかを手元で確認する。

```bash
ssh -i ./deploy_key -p 22 deploy@192.168.1.30 "echo 接続成功 && whoami"
```

```text
The authenticity of host '192.168.1.30 (192.168.1.30)' can't be established.
ED25519 key fingerprint is SHA256:yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy.
Are you sure you want to continue connecting (yes/no/[fingerprint])? yes
Warning: Permanently added '192.168.1.30' (ED25519) to the list of known hosts.
接続成功
deploy
```

**何をしているか**: 初回接続時は「このサーバーは本当に接続先として正しいか」の確認を求められる(ホスト鍵の確認)。`yes`と答えると`~/.ssh/known_hosts`に記録され、以降は確認なしで接続できるようになる。GitHub Actions上ではこの対話的な確認ができないため、ワークフロー側では`StrictHostKeyChecking=accept-new`という設定で自動的に許可する([02-design.md](./02-design.md) 4.6節)。

「接続成功」「deploy」と表示されれば、Step 2〜3で行った鍵の設定が正しく機能していることが確認できた。

## Step 5. GitHubリポジトリの準備

動作確認用のGitHubリポジトリを用意する(ブラウザのGitHub画面、または`gh repo create`で作成)。

```bash
gh repo create sample-shoji/cicd-demo-app --private --clone
cd cicd-demo-app
```

```text
✓ Created repository sample-shoji/cicd-demo-app on GitHub
  https://github.com/sample-shoji/cicd-demo-app
Cloning into 'cicd-demo-app'...
```

💡ポイント: `gh`を使わない場合は、ブラウザでリポジトリを作成した後、`git clone`でローカルへ持ってくれば同じ状態になる。以降の手順はどちらの方法でも共通。

## Step 6. リポジトリへのファイル配置

このポートフォリオの`src/`配下の内容を、対象リポジトリの直下へコピーする([02-design.md](./02-design.md) 6.2節の対応表を参照)。

```bash
mkdir -p .github/workflows app/css scripts

cp /path/to/projects/06-cicd-pipeline/src/.github/workflows/deploy.yml .github/workflows/deploy.yml
cp /path/to/projects/06-cicd-pipeline/src/app/index.html app/index.html
cp /path/to/projects/06-cicd-pipeline/src/app/css/style.css app/css/style.css
cp /path/to/projects/06-cicd-pipeline/src/scripts/test.sh scripts/test.sh
cp /path/to/projects/06-cicd-pipeline/src/scripts/deploy.sh scripts/deploy.sh

chmod +x scripts/test.sh scripts/deploy.sh
```

**確認**:

```bash
find . -not -path './.git*' -type f | sort
```

```text
./.github/workflows/deploy.yml
./app/css/style.css
./app/index.html
./scripts/deploy.sh
./scripts/test.sh
```

## Step 7. ローカルでの事前確認

GitHubへpushする前に、CIと同じチェックを手元で先に実行しておく。ここで見つかる問題は、CI上で発見するより手元で直した方が速い。

```bash
shellcheck scripts/*.sh
echo "shellcheckの終了コード: $?"
```

```text
shellcheckの終了コード: 0
```

```bash
bash scripts/test.sh
```

```text
=== [1/3] 必須ファイルの存在チェック ===
OK: index.html が存在します
OK: css/style.css が存在します
=== [2/3] index.htmlの基本構造チェック ===
OK: DOCTYPE宣言と<html>〜</html>タグの対応が確認できました
=== [3/3] <div>タグの開始/終了タグ数の一致チェック ===
OK: <div>の開始タグ(2個)と終了タグ(2個)が一致しています
------------------------------------------------------------
=== すべてのテストに合格しました ===
```

💡ポイント: 「CIで初めて気づく」よりも「手元で先に気づく」方が、修正して再pushするサイクルが速い。CIはあくまで**最後の砦**であり、開発者自身が事前にセルフチェックする習慣を持つことが、CI/CDを快適に運用するコツ。

## Step 8. GitHub Secretsの登録

[01-requirements.md](./01-requirements.md) 6章の6項目を、GitHubリポジトリのSecretsとして登録する。`gh secret set`コマンドを使うと、ブラウザを開かずターミナルから登録できる。

```bash
gh secret set DEPLOY_HOST --body "192.168.1.30"
gh secret set DEPLOY_USER --body "deploy"
gh secret set DEPLOY_PORT --body "22"
gh secret set DEPLOY_PATH --body "/var/www/sample-app"
gh secret set DEPLOY_SSH_KEY < ./deploy_key
gh secret set SLACK_WEBHOOK_URL --body "<YOUR_SLACK_WEBHOOK_URL>"
```

```text
✓ Set Secret DEPLOY_HOST for sample-shoji/cicd-demo-app
✓ Set Secret DEPLOY_USER for sample-shoji/cicd-demo-app
✓ Set Secret DEPLOY_PORT for sample-shoji/cicd-demo-app
✓ Set Secret DEPLOY_PATH for sample-shoji/cicd-demo-app
✓ Set Secret DEPLOY_SSH_KEY for sample-shoji/cicd-demo-app
✓ Set Secret SLACK_WEBHOOK_URL for sample-shoji/cicd-demo-app
```

**何をしているか**: `DEPLOY_SSH_KEY`だけは`< ./deploy_key`のように**ファイルの中身をそのまま**渡している点に注意。秘密鍵は改行を含む複数行のテキストのため、`--body`で1行の文字列として貼り付けると改行が壊れやすい。ファイルから読み込む方法だと、改行を含めて正確に登録できる。

ブラウザから登録する場合は、リポジトリの **Settings → Secrets and variables → Actions → New repository secret** から、同じ6つの名前と値を1つずつ登録する。

💡ポイント: 登録後、Secretsの値は画面上でもう一度表示することはできない(4.4節参照)。値を間違えて登録してしまった場合は、同じ名前で**上書き登録**すれば直せる。

登録できているか(値そのものではなく、登録済みの名前一覧)は以下で確認できる。

```bash
gh secret list
```

```text
NAME                UPDATED
DEPLOY_HOST          about 1 minute ago
DEPLOY_PATH          about 1 minute ago
DEPLOY_PORT          about 1 minute ago
DEPLOY_SSH_KEY       about 1 minute ago
DEPLOY_USER          about 1 minute ago
SLACK_WEBHOOK_URL    about 1 minute ago
```

## Step 9. Slack Incoming Webhookの準備

Incoming Webhook(=あらかじめ発行された専用URLへHTTPリクエスト(`curl`等)を送るだけで、対応するSlackチャンネルへメッセージを投稿できる仕組み)を準備する。

1. Slackで通知を送りたいワークスペースを開き、「App管理」→「Incoming Webhooks」を追加する
2. 通知先チャンネルを選択し、発行されたWebhook URL(`https://hooks.slack.com/services/...`)をコピーする
3. Step 8で登録した`SLACK_WEBHOOK_URL`の値を、実際に発行されたURLに置き換える(`gh secret set SLACK_WEBHOOK_URL --body "実際のURL"`で上書き)

疎通確認だけ先に行いたい場合は、単体で以下を実行する。

```bash
curl -s -X POST -H 'Content-type: application/json' \
    --data '{"text": "疎通テストです"}' \
    "<YOUR_SLACK_WEBHOOK_URL>"
```

Slackの対象チャンネルに「疎通テストです」と投稿されれば疎通OK。

## Step 10. pushしてパイプラインを起動する

いよいよ`main`ブランチへpushし、ワークフローを起動する。

```bash
git add .
git commit -m "Add CI/CD pipeline for sample app"
git push origin main
```

```text
Enumerating objects: 9, done.
...
To https://github.com/sample-shoji/cicd-demo-app.git
 * [new branch]      main -> main
```

💡ポイント: 本ポートフォリオ自体のリポジトリに対しては**git操作を行わない**方針だが、この手順は「実際に構築する対象リポジトリ(`cicd-demo-app`のような別リポジトリ)」に対して行うものである。混同しないよう注意する。

## Step 11. GitHub Actionsの実行結果を確認する

`gh run watch`を使うと、実行中のワークフローの進捗をターミナル上でリアルタイムに追える。

```bash
gh run list --limit 3
```

```text
STATUS  TITLE                          WORKFLOW                  BRANCH  EVENT  ID           ELAPSED  AGE
✓       Add CI/CD pipeline for sample  CI/CD Pipeline - Deploy…  main    push   1234567890   38s      1m
```

```bash
gh run watch 1234567890
```

```text
✓ actions/checkout@v4
✓ Install ShellCheck
✓ Run ShellCheck on shell scripts
✓ Run application smoke tests
test in 22s (ID 1234567891)

✓ actions/checkout@v4
✓ Write deploy SSH private key to file
✓ Run deploy script (rsync over SSH)
✓ Remove private key file
✓ Notify deploy result to Slack
deploy in 14s (ID 1234567892)

✓ Run CI/CD Pipeline - Deploy Web App#3
```

**何をしているか**: `test`ジョブ・`deploy`ジョブそれぞれのステップが順番に✓(緑)になっていく様子を確認できる。1つでも✗(失敗)になった場合は、そのステップ名をクリック(ブラウザ)または`gh run view --log`(CLI)でログを確認する。

```bash
gh run view 1234567890 --log | tail -n 20
```

Slackにも以下のようなメッセージが届く。

```text
✅ [sample-shoji/cicd-demo-app] デプロイ成功 (commit: a1b2c3d)
```

## Step 12. デプロイ先サーバーでの反映確認

実際にサイトが更新されているかを確認する。

```bash
curl -s http://192.168.1.30/ | grep "<h1>"
```

```text
  <h1>株式会社サンプル商事</h1>
```

`deploy-info.txt`から、どのコミットがいつデプロイされたかも確認できる。

```bash
curl -s http://192.168.1.30/deploy-info.txt
```

```text
deployed_at=2026-08-31 14:02:07
git_commit=a1b2c3d
```

`git_commit`の値が、Step 10でpushしたコミットのハッシュ(`git log --oneline -1`で確認できる先頭7文字)と一致していれば、意図した内容が正しくデプロイされたことが確認できる。

## Step 13. pull_requestトリガーの動作確認(デプロイされないことの確認)

featureブランチを切って変更を加え、`main`向けのプルリクエストを作成する。ここでは「テストは走るが、デプロイはされない」ことを確認する。

```bash
git checkout -b feature/update-title
# app/index.html のタイトルなどを少し変更したと仮定
git add app/index.html
git commit -m "Update title"
git push origin feature/update-title

gh pr create --base main --head feature/update-title \
  --title "Update title" --body "動作確認用のPR"
```

```text
https://github.com/sample-shoji/cicd-demo-app/pull/1
```

```bash
gh pr checks 1
```

```text
NAME  DESCRIPTION  STATUS
test  Lint & Test  ✓ pass
```

**確認できたこと**: PR上では`test`ジョブだけが実行され、`deploy`ジョブは一覧に出てこない(実行されていない)。これは[02-design.md](./02-design.md) 5章のNo.4パターン(`pull_request`トリガーではdeployしない)が意図通り動いていることの確認になる。

このPRを`main`へマージすれば、あらためて`push`トリガーとして`test`→`deploy`のフルパイプラインが実行される。

## Step 14. 最終確認チェックリスト

| 確認項目 | コマンド/確認方法 | 期待結果 |
|---|---|---|
| ワークフローファイルの配置場所 | `ls .github/workflows/deploy.yml` | ファイルが存在する |
| ローカルでのshellcheck | `shellcheck scripts/*.sh; echo $?` | `0` |
| ローカルでのtest.sh | `bash scripts/test.sh; echo $?` | `0` |
| Secretsの登録状況 | `gh secret list` | 6項目すべてが表示される |
| mainへのpushでtest→deployが実行される | `gh run list --limit 1` | `test`・`deploy`とも✓ |
| デプロイ結果がSlackに届く | Slackチャンネルを確認 | ✅または🔴のメッセージが届いている |
| サーバー側に反映されている | `curl http://<サーバー>/deploy-info.txt` | 最新コミットのハッシュと日時が表示される |
| pull_requestではデプロイされない | `gh pr checks <PR番号>` | `test`のみ表示され、`deploy`は実行されない |
| デプロイ用SSH鍵が個人の鍵と別である | Step 2で作成した`deploy_key`を使用 | 個人の`~/.ssh/id_ed25519`等と別ファイルになっている |

すべて満たしていれば構築完了。詳細なテストケースは[04-test-plan.md](./04-test-plan.md)を参照。
