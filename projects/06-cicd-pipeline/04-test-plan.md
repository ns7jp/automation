# 04. テスト仕様書

[03-build-guide.md](./03-build-guide.md)の手順で構築した環境に対して実施するテストケース一覧。正常系(想定通りに動くこと)と異常系(想定外の状況でも安全に倒れ、原因が分かる形で失敗すること)の両方を確認する。

## 1. テスト方針

- 実際に動作確認用のGitHubリポジトリ(`cicd-demo-app`など)とデプロイ先サーバーを用意し、featureブランチでの変更・pull_requestの作成・`main`へのマージという一連の流れを実際に再現しながら確認する
- 異常系の多くは、Secretsの値やスクリプトの内容を**一時的に**壊してpushし、想定通りワークフローが失敗することを確認した後、必ず元の状態に戻す
- 「どのジョブ・どのステップで失敗したか」を`gh run view --log`またはブラウザのActions画面で確認することを、各テストケースの基本動作とする

## 2. テストケース一覧

### 2.1 正常系

| テストID | 前提条件 | 操作手順 | 期待結果 |
|---|---|---|---|
| TC-01 | shellcheck・test.shがともに問題なく通る状態のコード | `main`ブランチへpushする | `test`ジョブ・`deploy`ジョブがともに成功(緑)になる。Slackに`✅ デプロイ成功`が届く |
| TC-02 | 同上 | `main`向けのpull_requestを作成する(mainへは直接pushしない) | `test`ジョブのみ実行され成功する。`deploy`ジョブは一覧に現れない(実行されない) |
| TC-03 | 同上 | `main`以外のブランチ(例: `feature/xxx`)へpushする(PRは作らない) | ワークフローの実行履歴が1件も作られない(`on.push.branches`の対象外のため) |
| TC-04 | 同上 | GitHubのActions画面(または`gh workflow run`)から手動実行(`workflow_dispatch`)する | `test`→`deploy`のフルパイプラインが実行され成功する |
| TC-05 | `app/index.html`の見出しや本文の文言を少し変更する等、タグ構造を崩さない通常の更新を加える | `main`へpushする | 変更後の内容で`test.sh`が正しく合否判定し、問題が無ければ成功する |
| TC-06 | 初回デプロイがまだ行われていない、まっさらなサーバー | `main`へpushしてデプロイを実行する | デプロイ先に`index.html`・`css/style.css`・`deploy-info.txt`一式が新規作成される |
| TC-07 | サーバー上に、リポジトリには存在しない古いファイル(例: `old.html`)が残っている状態 | `main`へpushしてデプロイを実行する | `rsync --delete`により`old.html`がサーバー上から削除される(転送元に無いものは反映先からも消える) |
| TC-08 | 同上の環境が用意できている | 短い間隔(数秒以内)で2回連続`main`へpushする | `concurrency`設定により2つ目のワークフローが「待機中」になり、1つ目の完了後に順番に実行される(同時に2つのdeployジョブが並行して動かない) |
| TC-09 | Step 8までのSecrets登録が完了している | `main`へpushし、`deploy`ジョブの各ステップのログを確認する | `DEPLOY_SSH_KEY`や`SLACK_WEBHOOK_URL`の値がログ上に平文で表示されず、`***`にマスクされている |
| TC-10 | 同上 | `deploy`ジョブ完了後、そのジョブのワークスペースを確認する(ジョブ終了後は参照できないため、"Remove private key file"ステップが実行されたことをログで確認) | `deploy_key`ファイルの削除ステップが実行済み(✓)になっている |

### 2.2 異常系

| テストID | 前提条件 | 操作手順 | 期待結果 |
|---|---|---|---|
| TC-11 | `scripts/deploy.sh`に、意図的に引用符を外した行(例: `rsync -avz --delete $SRC $DEST`)を追加する | `main`へpushする | `test`ジョブの`Run ShellCheck`ステップが`SC2086`等の指摘により失敗する。`deploy`ジョブは実行されない |
| TC-12 | `app/index.html`を一時的にリネームまたは削除する | `main`へpushする | `test`ジョブの`Run application smoke tests`ステップが「index.htmlが見つかりません」で失敗する。`deploy`ジョブは実行されない |
| TC-13 | `DEPLOY_HOST`のSecretsを一時的に削除する | `main`へpushする(`test`は成功する状態) | `deploy`ジョブの`deploy.sh`実行時、`環境変数 DEPLOY_HOST が未設定です`というメッセージとともに即座に終了コード`1`で失敗する(`DEPLOY_SSH_KEY`はワークフロー側で常に`deploy_key`というファイルパスとして渡されるため、この`:?`チェックでは検出できない点に注意) |
| TC-14 | デプロイ先サーバーの`authorized_keys`から、CI用の公開鍵を一時的に削除する | `main`へpushする | `deploy`ジョブが`Permission denied (publickey)`で失敗する。Slackに`🔴 デプロイ失敗`が届く |
| TC-15 | `DEPLOY_HOST`のSecretsを存在しないIPアドレス(例: `192.0.2.1`。ドキュメント用の予約アドレス)に一時変更する | `main`へpushする | `deploy`ジョブがSSH接続のタイムアウトで失敗する(数十秒後にタイムアウトエラー) |
| TC-16 | デプロイ先の`DEPLOY_PATH`を、`deploy`ユーザーに書き込み権限が無いディレクトリ(例: `/root/no-access`)に一時変更する | `main`へpushする | `rsync`が`Permission denied`エラーで失敗し、`deploy`ジョブが失敗する |
| TC-17 | `SLACK_WEBHOOK_URL`のSecretsを無効な値(存在しないURL)に一時変更し、TC-01相当のデプロイを行う | `main`へpushする | rsyncによるデプロイ自体は成功するが、Slackへの通知は届かない。ただし`curl`に`-f`を付けていないため、通知ステップ自体は失敗(✗)として記録されない(=通知の失敗が全体のジョブ結果を巻き込まない設計。[05-troubleshooting.md](./05-troubleshooting.md) Q6参照) |
| TC-18 | `.github/workflows/deploy.yml`のインデントを1箇所崩す等、意図的にYAML構文を壊す | `main`へpushする | ワークフロー自体が起動せず、GitHubのActions画面に「Invalid workflow file」というエラーが表示される。`test`・`deploy`いずれのジョブも実行履歴に現れない |

## 3. テスト結果の記録方法

各テストケースについて、実施日・実施者・結果(OK/NG)・実行ログのURLまたは抜粋を記録する。以下は記録テンプレートの例。

```text
テストID: TC-14
実施日: 2026-08-31
実施者: (氏名)
結果: OK
実行ログ抜粋:
  Permission denied (publickey).
  rsync: connection unexpectedly closed (0 bytes received so far) [sender]
  rsync error: unexplained error (code 255) at io.c(...) [sender=3.2.7]
備考: authorized_keysの公開鍵を元に戻した後、再度pushして正常にデプロイできることを再確認済み。
```

## 4. 完了基準

- TC-01〜TC-18のすべてが期待結果通りであること
- 異常系テスト(TC-11〜TC-18)で一時的に変更したSecrets・ファイル・設定が、テスト後にすべて元の状態へ戻っていること
- Slack通知(成功・失敗の両方)が実際にチャンネルへ届くことを、目視で最低1回ずつ確認していること
- `main`ブランチへの直接pushと、pull_request経由でのマージの両方で、想定通りの挙動(デプロイされる/されない)になることを確認していること
