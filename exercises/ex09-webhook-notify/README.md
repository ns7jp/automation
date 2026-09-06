# ex09: 失敗時のWebhook通知

| 項目 | 内容 |
|---|---|
| ステージ | 2: バックアップと定期実行 |
| 難易度 | ★★★☆☆ |
| 目安時間 | 50分 |
| 身につく力 | 環境変数で秘密情報を渡す / JSONの組み立てとエスケープ / curl でのPOST |
| 対応する案件 | [案件No.2 バックアップ自動化](../../projects/02-backup-automation/README.md) |
| 作業するファイル | `work/notify.sh` |

---

## 1. どんな場面で必要になるか

深夜2時に動くバックアップが3週間前から失敗していた、と気づいたのが「復旧が必要になった当日」だった。これは実際に起きる事故です。cron から動かすスクリプトの出力は誰も見ないので、**失敗しても誰も気づかない**のが最大の問題になります。

そこで実務では、処理の結果を Slack や Microsoft Teams のチャンネルに自動投稿します。これらのサービスは **Webhook (ウェブフック)** という仕組みを持っていて、決められたURLに決められた形式のデータを POST するだけでチャンネルに書き込めます。専用のアプリを作る必要はなく、`curl` 1行で済みます。

この演習では、その通知部分だけを小さなスクリプトとして切り出して書きます。切り出しておくと、バックアップからもログ監視からも死活監視からも同じスクリプトを呼べます。案件No.2の `backup.sh` にある `notify_slack` 関数が、まさにこの処理にあたります。

---

## 2. この演習で学ぶこと

| 学ぶこと | ひとことで言うと |
|---|---|
| 環境変数で秘密情報を渡す | WebhookのURLは合言葉。スクリプトにもリポジトリにも書かない |
| `${VAR:-}` | 「未定義なら空文字として扱う」書き方。`set -u` と組み合わせて使う |
| JSONの組み立て | `{"text":"..."}` という文字列を自分で作って `-d` で渡す |
| エスケープ | 値に `"` が入るとJSONが壊れる。`\"` に置換してから入れる |
| `curl` のPOST | `-sS` `-X POST` `-H` `-d` の4点セット |
| 通知失敗の扱い | 「通知できないこと」と「処理が失敗したこと」は別ものとして設計する |

### 3分でわかる予備知識

**Webhook とは**

「このURLにデータを送ると、Slackのこのチャンネルに書き込まれる」という**投稿専用の受付URL**のことです。Slackなら次のような形をしています。

```text
https://hooks.slack.com/services/<ワークスペースID>/<チャンネルID>/<ランダムな文字列>
```

このURLを知っている人は誰でもそのチャンネルに投稿できてしまうため、**パスワードと同じ扱い**をします。GitHubに上げたスクリプトに直書きしてしまう事故は非常に多いので、必ず環境変数か、権限を絞った設定ファイルから読み込みます。

**環境変数の渡し方**

```bash
# その場かぎりで渡す(履歴に残したくないときに便利)
WEBHOOK_URL="https://example.com/hook" ./notify.sh failure "テスト"

# シェル全体に渡す
export WEBHOOK_URL="https://example.com/hook"
./notify.sh failure "テスト"
```

スクリプトの中では、ふつうの変数と同じように `"$WEBHOOK_URL"` で読めます。ただし渡し忘れることもあるので、`${WEBHOOK_URL:-}` と書いて「未定義なら空文字」として受け取り、`-z` で空かどうかを判定します。

```bash
if [[ -z "${WEBHOOK_URL:-}" ]]; then
    echo "未設定です"
fi
```

**JSONの組み立てとエスケープ**

JSONは値をダブルクォートで囲む形式です。シェルの文字列の中にダブルクォートを書くときは `\"` と打ち消します。

```bash
TEXT="[FAILURE] web01: 失敗しました"
PAYLOAD="{\"text\":\"${TEXT}\"}"
echo "$PAYLOAD"      # → {"text":"[FAILURE] web01: 失敗しました"}
```

問題は、**メッセージそのものにダブルクォートが入っている**ときです。

```text
入力: tar が "backup.tar.gz" の作成に失敗しました
壊れたJSON: {"text":"[FAILURE] web01: tar が "backup.tar.gz" の ..."}
                                          ↑ ここで文字列が終わったと解釈される
```

そこで、送信する前にメッセージ中の `"` をすべて `\"` に置き換えます。bashには置換の書き方が用意されています。

```bash
MESSAGE='tar が "backup.tar.gz" の作成に失敗しました'
ESCAPED="${MESSAGE//\"/\\\"}"     # // は「すべて置換」。/ ひとつだと最初の1件だけ
echo "$ESCAPED"                   # → tar が \"backup.tar.gz\" の作成に失敗しました
```

**curl でPOSTする**

```bash
curl -sS -X POST \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "$WEBHOOK_URL"
```

| オプション | 意味 |
|---|---|
| `-s` | 進捗メーターを表示しない。cronから動かすとログが汚れるため |
| `-S` | `-s` を付けていてもエラーだけは表示する。`-sS` はセットで使う |
| `-X POST` | POSTメソッドで送る |
| `-H "..."` | HTTPヘッダーを追加する。本文がJSONであることを相手に伝える |
| `-d "..."` | 送信する本文 |

`curl` は通信できなかったときに0以外の終了ステータスを返します。`if ! curl ...; then` と書けば「失敗したら」の処理を書けます。

---

## 3. 課題

`work/notify.sh` を編集し、次の仕様を満たすスクリプトを完成させてください。

```text
使い方: notify.sh <success|failure> <メッセージ>
```

### 仕様

| No. | 条件 | 期待する動作 |
|---|---|---|
| 1 | 引数がちょうど2個ではない | 使い方を**標準エラー出力**に表示し、終了ステータス `1` で終わる |
| 2 | 第1引数が `success` / `failure` 以外 | 使い方を**標準エラー出力**に表示し、終了ステータス `1` で終わる |
| 3 | 環境変数 `WEBHOOK_URL` が未設定または空 | `WEBHOOK_URL が未設定のため通知をスキップします` を**標準出力**に表示し、`curl` を実行せずに終了ステータス `0` で終わる |
| 4 | 引数が正しく `WEBHOOK_URL` もある | `WEBHOOK_URL` 宛に `curl` でPOSTし、終了ステータス `0` で終わる |
| 5 | 送信する本文 | `{"text":"[FAILURE] <ホスト名>: <メッセージ>"}` の形式。`success` のときはラベルを `[SUCCESS]` にする |
| 6 | メッセージにダブルクォートが含まれる | `\"` にエスケープしてから本文に入れる |
| 7 | 送信に成功した | `通知を送信しました: [FAILURE] <ホスト名>: <メッセージ>` を**標準出力**に表示する |
| 8 | `curl` が失敗した | `エラー: 通知の送信に失敗しました` を**標準エラー出力**に表示し、終了ステータス `1` で終わる |

- ラベルは `[SUCCESS]` / `[FAILURE]` の2種類だけです。**半角の角かっこ+すべて大文字**で書きます
- ホスト名は `hostname` コマンドの実行結果です
- ラベルとホスト名の区切りは**半角スペース**、ホスト名とメッセージの区切りは**半角コロン+半角スペース**です

### 送信するリクエスト

次の形で送信してください。ヘッダーの文字列 `Content-Type: application/json` もそのまま使います。

```bash
curl -sS -X POST \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" \
    "$WEBHOOK_URL"
```

`PAYLOAD` の中身は次のようになります (ホスト名が `web01` の場合)。

```text
{"text":"[FAILURE] web01: バックアップに失敗しました"}
```

応答本文は使わないので、`> /dev/null` で捨ててかまいません。

### 実行例

```text
$ export WEBHOOK_URL="https://hooks.example.com/services/T000/B000/XXXX"
$ ./notify.sh failure "バックアップに失敗しました"
通知を送信しました: [FAILURE] web01: バックアップに失敗しました

$ ./notify.sh success "バックアップが完了しました"
通知を送信しました: [SUCCESS] web01: バックアップが完了しました

$ unset WEBHOOK_URL
$ ./notify.sh failure "バックアップに失敗しました"
WEBHOOK_URL が未設定のため通知をスキップします

$ ./notify.sh
使い方: notify.sh <success|failure> <メッセージ>
  実行結果を Webhook (Slackなど) へ通知します。
  送信先は環境変数 WEBHOOK_URL で指定します。
$ echo $?
1
```

---

## 4. やり方

```bash
# 1. exercises ディレクトリに移動する
cd exercises

# 2. 編集する(エディタは vim でも nano でも VS Code でもよい)
nano ex09-webhook-notify/work/notify.sh

# 3. 動かしてみる(WEBHOOK_URL 未設定なら、通信せずスキップされる)
bash ex09-webhook-notify/work/notify.sh failure "テスト通知"

# 4. 採点する
./check.sh 09
```

採点では本物の `curl` はダミーに差し替えられます。実在しないURLを渡しても外部へ通信は発生しないので、安心して何度でも実行してください。

---

## 5. ヒント

自力で20分考えてから開いてください。段階的に答えに近づくよう3段階に分けています。

<details>
<summary>ヒント1: 処理の順番を決める</summary>

このスクリプトは「上から順に関門を通す」構造にすると素直に書けます。

1. 引数の個数は2個か → 違えば `exit 1`
2. 第1引数は `success` か `failure` か → 違えば `exit 1`
3. `WEBHOOK_URL` はあるか → 無ければメッセージを出して `exit 0`
4. ここまで来たら本文を組み立てて送信する
5. 送信に失敗したら `exit 1`、成功したら結果を表示して `exit 0`

3番だけ `exit 1` ではなく `exit 0` なのがポイントです。通知の宛先が設定されていないのは**エラーではなく設定の状態**であり、これを失敗扱いにすると、通知を使わないテスト環境でバックアップまで失敗扱いになってしまいます。

</details>

<details>
<summary>ヒント2: 使う文法の具体例</summary>

**引数の種別で分岐する**

```bash
case "$STATUS" in
    success) LABEL="[SUCCESS]" ;;
    failure) LABEL="[FAILURE]" ;;
    *)
        echo "エラー: 第1引数は success または failure を指定してください。" >&2
        exit 1
        ;;
esac
```

**未設定の環境変数を安全に読む**

```bash
if [[ -z "${WEBHOOK_URL:-}" ]]; then
    echo "..."
    exit 0
fi
```

**ダブルクォートのエスケープ**

```bash
ESCAPED_MESSAGE="${MESSAGE//\"/\\\"}"
```

`${変数//置換前/置換後}` の形です。置換前の `\"` は「ダブルクォートそのもの」、置換後の `\\\"` は「バックスラッシュ+ダブルクォート」を表します。

**curl の失敗を捕まえる**

```bash
if ! curl -sS -X POST -H "..." -d "$PAYLOAD" "$WEBHOOK_URL" > /dev/null; then
    echo "エラー: ..." >&2
    exit 1
fi
```

</details>

<details>
<summary>ヒント3: 全体の骨組み</summary>

```bash
#!/bin/bash
set -u

usage() {
    echo "使い方: $(basename "$0") <success|failure> <メッセージ>"
}

if [[ "$#" -ne 2 ]]; then
    usage >&2
    exit 1
fi

STATUS="$1"
MESSAGE="$2"

case "$STATUS" in
    success) LABEL="[SUCCESS]" ;;
    failure) LABEL="[FAILURE]" ;;
    *) usage >&2; exit 1 ;;
esac

if [[ -z "${WEBHOOK_URL:-}" ]]; then
    # スキップのメッセージを出して exit 0
    :
fi

HOST_NAME="$(hostname)"
ESCAPED_MESSAGE=" ... "          # メッセージの " を \" に置換する
TEXT="${LABEL} ${HOST_NAME}: ${ESCAPED_MESSAGE}"
PAYLOAD="{\"text\":\"${TEXT}\"}"

# curl で送信し、失敗したら exit 1
# 成功したら「通知を送信しました: ...」を表示して exit 0
```

</details>

---

## 6. よくあるつまずき

| 症状 | 原因と対処 |
|---|---|
| `WEBHOOK_URL: unbound variable` と出て止まる | `set -u` を付けた状態で `"$WEBHOOK_URL"` を直接参照している。判定するときは `${WEBHOOK_URL:-}` と書く |
| 本文が `{"text":"[FAILURE] web01: メッセージ"}` にならず `{ "text": ... }` のように空白が入る | JSON自体は空白があっても正しいが、この演習の採点は仕様どおりの並びを見ている。`"{\"text\":\"${TEXT}\"}"` の形で組み立てる |
| メッセージに `"` を入れると相手に届かない | エスケープしていない。`${MESSAGE//\"/\\\"}` で置換してから本文に入れる |
| 通知に失敗しても終了ステータスが0のまま | `curl` の戻り値を見ていない。`if ! curl ...; then` または `curl ...; if [[ "$?" -ne 0 ]]; then` で判定する |
| 採点で「curl を実行しない」の項目が落ちる | `WEBHOOK_URL` の判定より前に `curl` を書いてしまっている。判定を先に置いて、その場で `exit 0` する |
| 手元で試すと `curl: (6) Could not resolve host` と出る | 実在しないURLを指定しているだけなので問題ない。採点時は `curl` がダミーに差し替わるため、この現象は起きない |

`./check.sh 09` が失敗したときは、**「期待」と「実際」の差分**を必ず読んでください。`curl` の項目が落ちた場合は、ダミーコマンドに記録された実際の呼び出し内容がそのまま表示されます。

---

## 7. 発展課題(採点対象外)

余裕がある人向けの追加課題です。実務では「もう一歩の気配り」が評価されます。

1. `-r <回数>` オプションで再送回数を指定できるようにし、送信に失敗したら数秒待って再送する (`sleep` と `for`)
2. Slack の本文にラベルだけでなく絵文字 (`:x:` `:white_check_mark:`) を付け、失敗と成功を一目で見分けられるようにする
3. `WEBHOOK_URL` を環境変数ではなく `notify.conf` から読み込む方式に変え、`chmod 600` で権限を絞る運用にする (案件No.2の `backup.conf` と同じ考え方)

---

## 8. この演習と案件のつながり

案件No.2 `backup.sh` の `notify_slack` 関数が、この演習に対応しています。

- WebhookのURLを設定ファイルから読み込む → [`backup.conf`](../../projects/02-backup-automation/src/backup.conf) の `SLACK_WEBHOOK_URL`
- `curl` でJSONをPOSTする部分 → [`backup.sh`](../../projects/02-backup-automation/src/backup.sh) の `notify_slack()`
- 失敗したときに通知を呼び出す流れ → 同スクリプトの `notify_slack ":x: [バックアップ失敗] ..."`
- 案件では通知の成否を判定していませんが (通知の失敗でバックアップ処理を止めないため)、この演習では通知そのものが主役なので終了ステータスで成否を返しています

次は [ex10: cron定義を書く](../ex10-cron-schedule/README.md) に進んでください。
