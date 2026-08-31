# 構築手順書: Linuxユーザーアカウント一括作成・管理自動化ツール

対象案件: [README.md](./README.md) / 設計: [02-design.md](./02-design.md)

本書は、検証用のLinuxサーバー(またはVM)を用意した状態から、スクリプトを配置し、動作確認まで完了させる手順を1ステップずつ説明する。コマンドは実際に実行して出力を確認済みのものを掲載している。

## 0. 前提条件

| 項目 | 内容 |
|---|---|
| OS | Ubuntu Server 22.04 LTS(VirtualBox上のVM、またはクラウドの無料枠インスタンスなど) |
| アカウント | `sudo` 権限を持つ一般ユーザー(例: `ictadmin`)でログインできること |
| ネットワーク | インターネット接続は必須ではない(パッケージ追加インストールなし) |

> 💡ポイント: 本ツールは `useradd` などOS標準コマンドのみで動作するため、追加のパッケージインストールは不要。「動かない環境がない」ことも、業務で使うツールを作る上での重要な設計方針。

## 1. 検証環境へのログインと権限確認

```bash
ssh ictadmin@192.0.2.10
sudo -v
```

**何をしているか:** SSHで検証サーバーにログインし、`sudo -v` でsudo権限があることを確認する。
**なぜ必要か:** 本ツールはroot権限が必須(要件F-09)のため、事前にsudoが使えるアカウントであることを確認しておく。

出力イメージ:

```text
[sudo] password for ictadmin:
```

パスワードを入力してエラーが出なければ権限OK。

## 2. 作業ディレクトリの準備

```bash
sudo mkdir -p /opt/account-tool
sudo chown "$(whoami)" /opt/account-tool
cd /opt/account-tool
```

**何をしているか:** ツール一式を配置する場所として `/opt/account-tool` を作成する。
**なぜ `/opt` なのか:** Linuxのディレクトリ構成の慣習(FHS = Filesystem Hierarchy Standard)では、`/opt` はOS標準以外に追加インストールしたアプリケーション・独自ツールの置き場所として使われる。個人のホームディレクトリ(`/home/ictadmin`)に置くと、担当者が変わったときや別アカウントで実行するときに混乱しやすい。

## 3. スクリプト一式の配置

検証機にリポジトリをクローンできる場合:

```bash
git clone <このリポジトリのURL> /tmp/automation
cp /tmp/automation/projects/01-user-account-automation/src/create_users.sh .
cp /tmp/automation/projects/01-user-account-automation/src/users.csv.sample ./users.csv
```

クローンできない場合は、`src/create_users.sh` と `src/users.csv.sample` の中身を `scp` や手元のエディタでそのまま検証機にコピーしてもよい。

**何をしているか:** スクリプト本体とサンプルCSVを作業ディレクトリに配置する。
**なぜコピー先を `users.csv`(拡張子だけ)にするか:** `.sample` はあくまで見本ファイルであり、実運用では担当者が人事から届いたデータでその都度中身を差し替えるため、区別しやすいようにサンプルとは別名で運用する。

## 4. 実行権限の付与

```bash
chmod +x create_users.sh
ls -l create_users.sh
```

**何をしているか:** スクリプトファイルに実行権限(`x`)を付与する。
**なぜ必要か:** Linuxではファイルの中身がシェルスクリプトであっても、実行権限(`x`)が付いていなければ `./create_users.sh` のように直接実行できない。

出力イメージ:

```text
-rwxr-xr-x 1 ictadmin ictadmin 9012  4月  1 09:00 create_users.sh
```

先頭が `-rwxr-xr-x` のように `x` を含んでいればOK。

> 💡ポイント: `chmod +x` を忘れて `./create_users.sh` を実行すると `-bash: ./create_users.sh: Permission denied` になる。よくあるつまずきポイントなので、[05-troubleshooting.md](./05-troubleshooting.md) のQ1も参照。

## 5. ヘルプ表示で使い方を確認

```bash
./create_users.sh -h
```

**何をしているか:** `-h` オプションでヘルプを表示する。ヘルプ表示は変更を伴わないため、root権限がなくても実行できる。
**なぜ最初に確認するか:** オプションの意味を実行前に把握しておくことで、本番実行時のミスを減らせる。

出力イメージ:

```text
使い方: create_users.sh [オプション]

CSVファイルを読み込み、Linuxユーザーアカウントを一括作成します。
CSVの列順は「氏名,ユーザー名,部署(グループ),初期パスワード」固定です。

オプション:
  -f <file>      読み込むCSVファイルのパス (デフォルト: users.csv)
  -l <dir>       ログ出力先ディレクトリ   (デフォルト: ./logs)
  -n             ドライランモード。実際には変更を加えず、
                 何が実行されるかだけを画面とログに出力します。
                 --dry-run も同じ意味で使えます。
  -h             このヘルプを表示して終了します。--help も同じ意味です。

実行例:
  sudo create_users.sh -f users.csv          # 本番実行(要root権限)
  sudo create_users.sh -f users.csv -n       # ドライラン(root権限は必要だが変更なし)
  create_users.sh -h                         # ヘルプ表示のみ(root権限不要)
```

## 6. 入力CSVの中身を確認する

```bash
cat users.csv
```

出力イメージ:

```text
氏名,ユーザー名,部署,初期パスワード
山田太郎,yamada_t,eigyo,ChangeMe123!
鈴木花子,suzuki_h,soumu,ChangeMe123!
佐藤健二,sato_k,kaihatsu,ChangeMe123!
田中美咲,tanaka_m,keiri,ChangeMe123!
```

**何をしているか:** これから処理する対象データを目視確認する。
**なぜ必要か:** ツールに読み込ませる前に、部署名(グループ名)のスペルミスやユーザー名の重複がないかを人の目でも確認する習慣をつけておくと、事故を未然に防ぎやすい。

## 7. root権限チェックの動作を確認する(あえて一般ユーザーで実行)

```bash
./create_users.sh -f users.csv
```

**何をしているか:** `sudo` を付けずに実行し、要件F-09のroot権限チェックが正しく働くかを確認する。
**なぜこの確認が重要か:** 「エラーにすべき操作が、実際にちゃんとエラーになる」ことを確認するのも動作確認の一部。異常系の動作確認は正常系と同じくらい重要。

出力イメージ:

```text
エラー: このスクリプトはroot権限で実行してください。(例: sudo create_users.sh -f users.csv)
```

終了ステータスも確認しておく。

```bash
echo $?
```

```text
1
```

## 8. ドライランで動作確認する

```bash
sudo ./create_users.sh -f users.csv -n
```

**何をしているか:** `-n`(`--dry-run`)を付けてroot権限で実行する。実際のアカウント作成・変更は一切行われない。
**なぜ本番実行の前に必ずやるか:** CSVの入力ミスや、想定外の件数が処理対象になっていないかを、システムに変更を加える前に確認できる。要件F-08・N-02に対応する最重要ステップ。

出力イメージ:

```text
[2026-04-01 09:05:12] [INFO] ===== ユーザーアカウント一括作成処理を開始します =====
[2026-04-01 09:05:12] [INFO] CSVファイル: users.csv
[2026-04-01 09:05:12] [INFO] ログファイル: ./logs/create_users_20260401_090512.log
[2026-04-01 09:05:12] [INFO] ドライランモードで実行しています。実際のアカウント作成・変更は行いません。
[2026-04-01 09:05:12] [INFO] [dry-run] グループ eigyo が存在しないため作成します(実際には作成していません)
[2026-04-01 09:05:12] [INFO] [dry-run] ユーザー yamada_t (氏名: 山田太郎 / 部署: eigyo) を作成します(実際には作成していません)
[2026-04-01 09:05:12] [INFO] [dry-run] グループ soumu が存在しないため作成します(実際には作成していません)
[2026-04-01 09:05:12] [INFO] [dry-run] ユーザー suzuki_h (氏名: 鈴木花子 / 部署: soumu) を作成します(実際には作成していません)
[2026-04-01 09:05:12] [INFO] [dry-run] グループ kaihatsu が存在しないため作成します(実際には作成していません)
[2026-04-01 09:05:12] [INFO] [dry-run] ユーザー sato_k (氏名: 佐藤健二 / 部署: kaihatsu) を作成します(実際には作成していません)
[2026-04-01 09:05:12] [INFO] [dry-run] グループ keiri が存在しないため作成します(実際には作成していません)
[2026-04-01 09:05:12] [INFO] [dry-run] ユーザー tanaka_m (氏名: 田中美咲 / 部署: keiri) を作成します(実際には作成していません)
[2026-04-01 09:05:12] [INFO] ===== 処理結果サマリ =====
[2026-04-01 09:05:12] [INFO] 成功: 4件 / スキップ: 0件 / 失敗: 0件
[2026-04-01 09:05:12] [INFO] ドライランモードのため、実際のアカウント作成・変更は行われていません。
[2026-04-01 09:05:12] [INFO] ===== 処理を終了します =====
```

「成功: 4件」と表示されたユーザーが、CSVの4件と一致していることを確認する。

## 9. ログファイルの中身を確認する

```bash
ls -l logs/
cat logs/create_users_20260401_090512.log
```

**何をしているか:** ドライラン実行の結果が、画面表示と同じ内容でファイルにも保存されていることを確認する。
**なぜ必要か:** `tee -a` によって画面出力とログファイル出力が一致していることを確かめておくと、後で「ログを見れば実行結果を追跡できる」(要件N-04)ことに安心して運用できる。

## 10. 本番実行する

ドライランの結果に問題がなければ、`-n` を外して本番実行する。

```bash
sudo ./create_users.sh -f users.csv
```

出力イメージ:

```text
[2026-04-01 09:07:30] [INFO] ===== ユーザーアカウント一括作成処理を開始します =====
[2026-04-01 09:07:30] [INFO] CSVファイル: users.csv
[2026-04-01 09:07:30] [INFO] ログファイル: ./logs/create_users_20260401_090730.log
[2026-04-01 09:07:30] [INFO] グループ eigyo を新規作成しました。
[2026-04-01 09:07:30] [INFO] ユーザー yamada_t (氏名: 山田太郎 / 部署: eigyo) を作成しました。
[2026-04-01 09:07:30] [INFO] ユーザー yamada_t の初期パスワードを設定しました。
[2026-04-01 09:07:30] [INFO] ユーザー yamada_t に初回ログイン時のパスワード変更を強制しました。
[2026-04-01 09:07:30] [INFO] グループ soumu を新規作成しました。
[2026-04-01 09:07:30] [INFO] ユーザー suzuki_h (氏名: 鈴木花子 / 部署: soumu) を作成しました。
[2026-04-01 09:07:31] [INFO] ユーザー suzuki_h の初期パスワードを設定しました。
[2026-04-01 09:07:31] [INFO] ユーザー suzuki_h に初回ログイン時のパスワード変更を強制しました。
[2026-04-01 09:07:31] [INFO] グループ kaihatsu を新規作成しました。
[2026-04-01 09:07:31] [INFO] ユーザー sato_k (氏名: 佐藤健二 / 部署: kaihatsu) を作成しました。
[2026-04-01 09:07:31] [INFO] ユーザー sato_k の初期パスワードを設定しました。
[2026-04-01 09:07:31] [INFO] ユーザー sato_k に初回ログイン時のパスワード変更を強制しました。
[2026-04-01 09:07:31] [INFO] グループ keiri を新規作成しました。
[2026-04-01 09:07:31] [INFO] ユーザー tanaka_m (氏名: 田中美咲 / 部署: keiri) を作成しました。
[2026-04-01 09:07:31] [INFO] ユーザー tanaka_m の初期パスワードを設定しました。
[2026-04-01 09:07:31] [INFO] ユーザー tanaka_m に初回ログイン時のパスワード変更を強制しました。
[2026-04-01 09:07:31] [INFO] ===== 処理結果サマリ =====
[2026-04-01 09:07:31] [INFO] 成功: 4件 / スキップ: 0件 / 失敗: 0件
[2026-04-01 09:07:31] [INFO] ===== 処理を終了します =====
```

## 11. 作成結果を確認する

```bash
id yamada_t
getent group eigyo
chage -l yamada_t
```

**何をしているか:** `id` でユーザーが実際に作成されたか、`getent group` でグループ所属が正しいか、`chage -l` でパスワード期限の設定内容を確認する。
**なぜ確認するか:** ログ上は成功と出ていても、実際にOS側の状態が想定通りになっているかをコマンドで裏取りするのが確実な確認方法。

出力イメージ:

```text
$ id yamada_t
uid=1001(yamada_t) gid=1002(eigyo) groups=1002(eigyo)

$ getent group eigyo
eigyo:x:1002:

$ chage -l yamada_t
Last password change                                   : password must be changed
Password expires                                       : password must be changed
Password inactive                                       : password must be changed
Account expires                                        : never
Minimum number of days between password change          : 0
Maximum number of days between password change          : 99999
Number of days of warning before password expires       : 7
```

「Last password change : password must be changed」と表示されていれば、`chage -d 0` による初回ログイン時のパスワード変更強制(要件F-06)が正しく設定されている。

## 12. 再実行してスキップ動作(べき等性)を確認する

```bash
sudo ./create_users.sh -f users.csv
```

**何をしているか:** 同じCSVでもう一度実行する。
**なぜ確認するか:** 「誤って2回実行してしまっても壊れない」というべき等性(=同じ処理を何度実行しても結果が変わらない性質)が正しく機能しているかを確認する。実務でも「あれ、さっき実行したか覚えてない」という場面は起こり得るため、この安全性は重要。

出力イメージ:

```text
[2026-04-01 09:10:02] [INFO] ===== ユーザーアカウント一括作成処理を開始します =====
[2026-04-01 09:10:02] [INFO] CSVファイル: users.csv
[2026-04-01 09:10:02] [INFO] ログファイル: ./logs/create_users_20260401_091002.log
[2026-04-01 09:10:02] [SKIP] ユーザー yamada_t は既に存在するためスキップしました。
[2026-04-01 09:10:02] [SKIP] ユーザー suzuki_h は既に存在するためスキップしました。
[2026-04-01 09:10:02] [SKIP] ユーザー sato_k は既に存在するためスキップしました。
[2026-04-01 09:10:02] [SKIP] ユーザー tanaka_m は既に存在するためスキップしました。
[2026-04-01 09:10:02] [INFO] ===== 処理結果サマリ =====
[2026-04-01 09:10:02] [INFO] 成功: 0件 / スキップ: 4件 / 失敗: 0件
[2026-04-01 09:10:02] [INFO] ===== 処理を終了します =====
```

「成功: 0件 / スキップ: 4件」となっていれば、既存ユーザーへの重複作成が発生していないことが確認できる。

## 13. 後片付け(検証用アカウントの削除)

検証用に作成したアカウントは、確認が終わったら削除しておく。

```bash
sudo userdel -r yamada_t
sudo userdel -r suzuki_h
sudo userdel -r sato_k
sudo userdel -r tanaka_m
sudo groupdel eigyo
sudo groupdel soumu
sudo groupdel kaihatsu
sudo groupdel keiri
```

**何をしているか:** `userdel -r` はユーザーとホームディレクトリを削除、`groupdel` はグループを削除する。
**なぜ必要か:** 検証環境をきれいな状態に戻しておくことで、次回の動作確認(テスト仕様書のテストケースなど)を同じ条件で再実行できるようにするため。

> 💡ポイント: `userdel -r` の `-r` を忘れると、ユーザーアカウントだけ消えてホームディレクトリが残ってしまう。ディスクの片付けとしても `-r` を付ける習慣をつけておくとよい。

## 14. 次に読むドキュメント

- テストケースを一通り確認したい場合: [04-test-plan.md](./04-test-plan.md)
- エラーが出て困ったとき: [05-troubleshooting.md](./05-troubleshooting.md)

## 15. 関連ドキュメント

- [README.md](./README.md)
- [01-requirements.md](./01-requirements.md)
- [02-design.md](./02-design.md)
- [04-test-plan.md](./04-test-plan.md)
- [05-troubleshooting.md](./05-troubleshooting.md)
