# ex20: GitHub Actionsワークフローを書く

| 項目 | 内容 |
|---|---|
| ステージ | 6: CI/CD |
| 難易度 | ★★★★☆ |
| 目安時間 | 60分 |
| 身につく力 | ワークフローの構造 / uses と run / needs と if / Secrets |
| 対応する案件 | [案件No.6 CI/CDパイプライン](../../projects/06-cicd-pipeline/README.md) |
| 作業するファイル | `work/deploy.yml` |

---

## 1. どんな場面で必要になるか

社内向けWebサイトを3人で運用しているとします。更新のたびに担当者が手元から `rsync` でサーバーへコピーしていましたが、あるとき「テストを流さずに壊れたHTMLを上げてしまった」「担当者が休みで誰も配布方法を知らない」という事故が起きました。

この2つはどちらも「人が手で配布している」ことが原因です。そこで、**GitHubにコードを置いたら、自動で検査され、問題がなければ自動でサーバーへ配られる**仕組みを用意します。これがCI/CDです。CI(継続的インテグレーション)は「変更のたびに自動で検査する」こと、CD(継続的デリバリー)は「検査に通ったものを自動で届ける」ことを指します。

GitHubでこれを実現する仕組みが **GitHub Actions** です。リポジトリの `.github/workflows/` にYAMLファイルを置くだけで、pushやプルリクエストをきっかけに処理が動きます。

この演習では、案件No.6の [`.github/workflows/deploy.yml`](../../projects/06-cicd-pipeline/src/.github/workflows/deploy.yml) を初心者向けに削ぎ落とした版を、自分の手で書き上げます。

---

## 2. この演習で学ぶこと

| 学ぶこと | ひとことで言うと |
|---|---|
| `on` | いつワークフローを動かすか(トリガー)の指定 |
| `jobs` と `steps` | 仕事の単位と、その中で順に実行する手順 |
| `uses` と `run` の違い | 既製の部品を呼ぶのが `uses` 、コマンドを打つのが `run` |
| `needs` | 「このジョブが成功したら次へ」という順番の指定 |
| `if` | 条件を満たすときだけジョブを動かす指定 |
| Secrets | パスワードや秘密鍵を、ファイルに書かずに渡す仕組み |

### 3分でわかる予備知識

**YAMLの書き方**

YAMLは「見た目(インデント)がそのまま構造になる」設定ファイル形式です。ルールは4つだけです。

```yaml
name: deploy          # 「キー: 値」。コロンの後ろに半角スペースを1つ入れる
on:                   # 値を書かないと「この下にぶら下がる」という意味になる
  push:               # 半角スペース2つ下げると「on の中身」になる
    branches: [ main ]   # 角括弧で囲むとリスト([ ] の中に , 区切りで並べる)
```

- **インデントにタブは使えません。** 必ず半角スペースです。タブを1つでも混ぜると読み込みに失敗します。
- 行頭の `- ` は「リストの1要素」という意味です。
- `#` から行末まではコメントです。

**ワークフローの3階層**

GitHub Actions のファイルは、上から `on` / `jobs` / `steps` の3階層でできています。

```yaml
on:                          # (1) いつ動かすか
  push:
jobs:                        # (2) どんな仕事をするか
  test:                      #     ジョブ名は自分で決めてよい
    runs-on: ubuntu-latest   #     どのOSの仮想マシン(ランナー)を借りるか
    steps:                   # (3) その仕事の手順を上から順に実行する
      - uses: actions/checkout@v4
      - run: echo "hello"
```

**`uses` と `run` の違い**

| 書き方 | 意味 |
|---|---|
| `uses: actions/checkout@v4` | 世界中の人が公開している**既製の部品(Action)**を呼び出す。`@v4` はバージョン指定 |
| `run: bash scripts/test.sh` | 借りた仮想マシンの上で**シェルコマンドをそのまま実行**する |

`actions/checkout` は「リポジトリの中身を仮想マシンへ持ってくる」GitHub公式の部品です。これを最初に書かないと、仮想マシンは空っぽのままなので `scripts/test.sh` すら見つかりません。

複数行のコマンドを書きたいときは `|` を使います。

```yaml
      - name: 複数のコマンドを実行する
        run: |
          mkdir -p ~/.ssh
          chmod 700 ~/.ssh
```

**ステップの成否がワークフローの成否になる**

`run` で実行したコマンドの**終了ステータスが0以外**になると、そのステップは失敗し、ジョブ全体も失敗します。ex01で学んだ `exit 0` / `exit 1` が、ここでそのまま効いてきます。「テストが落ちたら配布しない」という安全装置は、この終了ステータスだけで成り立っています。

**`needs` と `if`**

ジョブは既定では**同時に**動きます。順番を付けたいときだけ `needs` を書きます。

```yaml
  deploy:
    needs: test                              # test が成功してから動く
    if: github.ref == 'refs/heads/main'      # main ブランチのときだけ動く
```

`github.ref` には「今動いているブランチの正式名」が入り、mainブランチなら `refs/heads/main` という文字列になります。`main` だけでは一致しないので注意してください。

**Secrets: 秘密鍵をリポジトリに置いてはいけない理由**

サーバーへ配布するにはSSHの秘密鍵が必要ですが、**秘密鍵をリポジトリに置いてはいけません。**

- Gitは履歴を残すため、あとからファイルを消しても**過去のコミットから復元できます**。
- リポジトリを公開に切り替えた瞬間、世界中から鍵が読めます。
- 公開リポジトリのSSH鍵は、自動巡回しているプログラムに数分で拾われるのが実情です。
- 拾われた鍵で本番サーバーにログインされると、被害はサーバー1台では済みません。

そこでGitHubの **Secrets** に値を預けます。Secretsに入れた値はワークフローの実行時にだけ差し込まれ、実行ログにも自動でマスク(`***` 表示)されます。

登録手順は次のとおりです。

1. GitHubでリポジトリを開く
2. `Settings` タブ → 左メニューの `Secrets and variables` → `Actions`
3. `New repository secret` を押す
4. Name に `SSH_PRIVATE_KEY` 、Secret に鍵の中身を貼り付けて `Add secret`
5. 同じ手順で `DEPLOY_USER`(接続ユーザー名)と `DEPLOY_HOST`(接続先ホスト名)も登録する

ワークフローからは `${{ secrets.名前 }}` の形で参照します。**一度登録したSecretsは画面からも読み出せません。** 上書きはできますが中身の確認はできない、という仕様です。

```yaml
        run: |
          echo "${{ secrets.SSH_PRIVATE_KEY }}" > ~/.ssh/id_ed25519
          chmod 600 ~/.ssh/id_ed25519
```

`chmod 600` は「持ち主だけが読み書きできる」権限にする指定です。SSHは、他人にも読める権限の秘密鍵を渡されると安全のために接続を拒否するので、これは必須です。

---

## 3. 課題

`work/deploy.yml` を編集し、次の仕様を満たすワークフローを完成させてください。

### 仕様

| No. | 条件 | 期待する動作 |
|---|---|---|
| 1 | ワークフローの名前 | 行頭に `name: deploy` と書く |
| 2 | main ブランチへの push | ワークフローが動く。`on:` の下に `push:` を書き、その下に `branches: [ main ]` |
| 3 | main ブランチ宛てのプルリクエスト | ワークフローが動く。`pull_request:` を書き、その下に `branches: [ main ]` |
| 4 | GitHubの画面から手動実行 | できるようにする。`workflow_dispatch:` をキーだけの行で書く |
| 5 | ジョブの数 | `jobs:` の下に `test` と `deploy` の2つ。どちらも `runs-on: ubuntu-latest` |
| 6 | 各ジョブの最初の手順 | 両方のジョブで `- uses: actions/checkout@v4` を書く |
| 7 | test ジョブの手順 | `run: shellcheck scripts/*.sh` と `run: bash scripts/test.sh` を順に実行する |
| 8 | deploy ジョブの前提 | `needs: test` を書き、test が成功したときだけ動かす |
| 9 | deploy ジョブの条件 | `if: github.ref == 'refs/heads/main'` を書き、mainのときだけ動かす |
| 10 | 秘密鍵の受け取り | `${{ secrets.SSH_PRIVATE_KEY }}` を参照する。鍵の中身は書かない |
| 11 | 秘密鍵ファイルの権限 | 書き出した鍵に `chmod 600` を実行する |
| 12 | 配布先の受け取り | `${{ secrets.DEPLOY_USER }}` と `${{ secrets.DEPLOY_HOST }}` の2種類を参照する |
| 13 | 書式 | インデントは半角スペース2つ。**タブ文字は使わない**。YAMLとして読み込めること |
| 14 | 雛形の後始末 | `TODO` と書かれたコメント行はすべて消す |

### 完成イメージ

```yaml
name: deploy

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]
  workflow_dispatch:

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: shellcheck で静的解析する
        run: shellcheck scripts/*.sh

      - name: テストを実行する
        run: bash scripts/test.sh

  deploy:
    needs: test
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: SSH秘密鍵を配置する
        run: |
          ...(ここを自分で書く)

      - name: rsync で配布する
        run: |
          ...(ここを自分で書く)
```

`...` の2か所は、次のことをしてください。

- **SSH秘密鍵を配置する**: `mkdir -p ~/.ssh` でディレクトリを作り、`${{ secrets.SSH_PRIVATE_KEY }}` の値を `~/.ssh/id_ed25519` へ書き出し、`chmod 600 ~/.ssh/id_ed25519` で権限を絞る
- **rsync で配布する**: `rsync -avz --delete -e "ssh -o StrictHostKeyChecking=no" app/ "${{ secrets.DEPLOY_USER }}@${{ secrets.DEPLOY_HOST }}:/var/www/html/"` を実行する

### 採点で見ている書き方

テストは次の文字列を**そのままの形**で探します。表記ゆれがあると不合格になります。

- `name: deploy` (行頭から書く)
- `push:` / `pull_request:` / `workflow_dispatch:` (コロンの後ろに値を書かない)
- `branches: [ main ]` (角括弧の内側は半角スペースで区切る)
- `jobs:` (行頭から書く)
- `runs-on: ubuntu-latest` が**2行**
- `- uses: actions/checkout@v4` が**2行**
- `needs: test`
- `if:` の行に `refs/heads/main` を含む
- `${{ secrets.SSH_PRIVATE_KEY }}` / `${{ secrets.DEPLOY_USER }}` / `${{ secrets.DEPLOY_HOST }}`
- `chmod 600`

---

## 4. やり方

```bash
# 1. exercises ディレクトリに移動する
cd exercises

# 2. 編集する(エディタは vim でも nano でも VS Code でもよい)
nano ex20-actions-workflow/work/deploy.yml

# 3. YAMLとして読み込めるか自分で確かめる(エラーが出なければOK)
python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' \
    ex20-actions-workflow/work/deploy.yml

# 4. 採点する
./check.sh 20
```

採点に合格すると、次のように表示されます。

```text
  ✓ [1] 雛形の TODO 行が残っていない
  ✓ [2] インデントにタブ文字を使っていない
  ...
  結果: 16/16 合格
```

---

## 5. ヒント

自力で20分考えてから開いてください。段階的に答えに近づくよう3段階に分けています。

<details>
<summary>ヒント1: 何を上から順に書けばよいか</summary>

このファイルは、上から次の3ブロックを書くだけです。

1. `name:` — ワークフローの名前
2. `on:` — いつ動かすか。中に `push:` `pull_request:` `workflow_dispatch:` の3つ
3. `jobs:` — 何をするか。中に `test:` と `deploy:` の2つ

迷ったら「浅いところから順に埋める」と考えてください。まず `name` と `on` だけ書いて、`python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' ...` で読み込めるか確かめ、通ったら `jobs` を足す、という進め方が確実です。

`test` ジョブと `deploy` ジョブは、どちらも同じ形をしています。

```yaml
  ジョブ名:
    runs-on: ubuntu-latest
    steps:
      - (手順1)
      - (手順2)
```

</details>

<details>
<summary>ヒント2: steps の3つの書き方</summary>

`steps:` の下に並べる要素には、次の3パターンがあります。どれも先頭の `- ` が「リストの1要素」を表しています。

```yaml
    steps:
      # (1) 既製の部品を呼ぶだけ
      - uses: actions/checkout@v4

      # (2) 名前を付けて1行コマンドを実行する
      - name: テストを実行する
        run: bash scripts/test.sh

      # (3) 名前を付けて複数行コマンドを実行する
      - name: 秘密鍵を置く
        run: |
          コマンド1
          コマンド2
```

(2) と (3) では、`name` と `run` が**同じ深さ**にそろっていることに注意してください。`- ` の分(半角スペース2つ)だけ下げた位置に `run` を書きます。

Secretsの参照は、コマンドの中に文字列としてそのまま埋め込みます。

```yaml
        run: |
          echo "${{ secrets.SSH_PRIVATE_KEY }}" > ~/.ssh/id_ed25519
```

</details>

<details>
<summary>ヒント3: 全体の骨組み</summary>

```yaml
name: deploy

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]
  workflow_dispatch:

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: shellcheck で静的解析する
        run: shellcheck scripts/*.sh

      # ここに「テストを実行する」ステップを足す

  deploy:
    # ここに needs と if を書く
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: SSH秘密鍵を配置する
        run: |
          mkdir -p ~/.ssh
          # ここで秘密鍵を ~/.ssh/id_ed25519 へ書き出し、権限を 600 にする

      # ここに rsync のステップを足す
```

</details>

---

## 6. よくあるつまずき

| 症状 | 原因と対処 |
|---|---|
| `yaml.scanner.ScannerError: found character '\t' that cannot start any token` | インデントにタブが混ざっている。エディタで「タブをスペースに変換」を有効にし、半角スペース2つに直す |
| `mapping values are not allowed in this context` | コロンの後ろの半角スペースが抜けている(`name:deploy` は誤り)。`name: deploy` と書く |
| pushしても何も動かない | ファイルの置き場所が違う。本番では `.github/workflows/deploy.yml` に置く。`on:` のブランチ名が実際のブランチ名と違う場合もある |
| プルリクエストのたびに本番へ配布されてしまう | `deploy` ジョブに `if: github.ref == 'refs/heads/main'` を書き忘れている |
| `Permission denied (publickey)` でSSHに失敗する | `chmod 600` を忘れている。権限が緩い秘密鍵はSSHが受け付けない |
| `scripts/test.sh: No such file or directory` | そのジョブに `- uses: actions/checkout@v4` が無い。ジョブごとにランナーはまっさらなので、両方のジョブに必要 |
| ログに秘密鍵がそのまま出てしまった | `${{ secrets.XXX }}` を使わず値を直接書いている。すぐに鍵を作り直し(ローテーション)、Secretsに登録し直す |

`./check.sh 20` が失敗したときは、**「期待」と「実際」の差分**を必ず読んでください。どの正規表現に一致しなかったかがそのまま書かれています。

---

## 7. 発展課題(採点対象外)

余裕がある人向けの追加課題です。実務では「もう一歩の気配り」が評価されます。

1. `permissions: contents: read` を足して、ワークフローに与える権限を最小限に絞る
2. `concurrency` を足して、短時間に複数回pushされてもデプロイが同時に走らないようにする
3. 最後に `if: always()` を付けたステップを足し、成功・失敗どちらの場合もSlackへ通知する

いずれも案件No.6の [`deploy.yml`](../../projects/06-cicd-pipeline/src/.github/workflows/deploy.yml) に実装があります。読み比べてみてください。

---

## 8. この演習と案件のつながり

案件No.6のワークフローは、この演習で書いたものに実運用向けの配慮を足したものです。

- トリガーの `on` と2ジョブ構成 → [`.github/workflows/deploy.yml`](../../projects/06-cicd-pipeline/src/.github/workflows/deploy.yml) の `on:` と `jobs:`
- `needs` と `if` によるデプロイの門番 → 同ファイル `deploy` ジョブの `needs: test` / `if:`
- Secretsによる秘密情報の受け渡し → 同ファイルの `${{ secrets.DEPLOY_SSH_KEY }}` ほか
- `run: bash scripts/test.sh` で呼ばれるテスト本体 → [`scripts/test.sh`](../../projects/06-cicd-pipeline/src/scripts/test.sh)(次のex21で自分で書きます)

次は [ex21: CIで動かすテストスクリプト](../ex21-ci-test-script/README.md) に進んでください。
