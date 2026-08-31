# 案件No.6: GitHub ActionsによるCI/CD自動デプロイパイプライン構築

## 難易度

★★★★★(上級)

案件No.1〜No.5は「1台のサーバー上で完結するスクリプト・サービス」の構築だったのに対し、本案件は**GitHubのクラウド上で動く自動化の仕組みそのもの**を設計・構築する点で毛色が異なる。YAMLによるワークフロー定義(トリガー・ジョブの依存関係・条件付き実行)、GitHub Secretsを使った機密情報管理、SSH鍵ペアの発行・受け入れ設定、rsyncによる差分同期、Slack通知、多重実行を防ぐ排他制御(concurrency)など、扱う技術要素の数が多く、かつ「CI(テスト)が通ったものだけをCD(デプロイ)する」というジョブ間の依存関係を正しく設計する必要があるため、上級に位置づけている。

## 想定依頼元・背景

| 項目 | 内容 |
|---|---|
| 依頼元 | 株式会社サンプル商事(架空社名。案件No.1・No.2・No.4・No.5と同一の会社という想定。案件No.3は別の架空チームを想定している) |
| 部署 | 開発部門(社内向けコーポレートサイトを担当するエンジニア2〜3名体制) |
| 課題 | Webアプリ(社内向けコーポレートサイト)の本番反映を、担当エンジニアが手作業で`scp`転送して行っていた。転送するファイルを目視で選んでいたため、更新したはずのファイルの反映漏れが度々発生し、また手順が担当者の頭の中にしかなく属人化していた |
| 要望 | 「GitHubにpushしたら自動でテスト・デプロイされる仕組みを作ってほしい。ただし、テストに通らないものが誤って本番に反映されるのは困るし、秘密鍵などをうっかりコードに書いてしまうような事故も防ぎたい」 |

「手作業のデプロイに限界を感じ、CI/CDパイプラインの導入に踏み切る」というのは、開発チームの規模がある程度大きくなった企業で必ず通る道の1つ。本案件はその典型的な導入初期のシナリオを題材にしている。

## 依頼内容(要求仕様)

- GitHubリポジトリの`main`ブランチへのpushをトリガーに、GitHub Actionsのワークフローが自動実行されること
- ワークフロー内で簡単な自動テスト(シェルスクリプトの構文チェック`shellcheck`、およびサンプルアプリの簡易テスト)を実行すること
- テストが成功した場合のみ、SSH経由で検証用/本番サーバーへ自動でファイルを転送・反映すること
- SSHの秘密鍵やサーバー情報などの機密情報は、GitHub Secretsを使って安全に管理すること(コードに直接書かないこと)
- デプロイの成功/失敗が、GitHub Actions上・通知(Slack)の両方から分かるようにすること

詳細は[01-requirements.md](./01-requirements.md)を参照。

## 成果物一覧

| No. | ファイル | 内容 |
|---|---|---|
| 1 | [README.md](./README.md) | 本ファイル。案件概要・アピールポイントまとめ |
| 2 | [01-requirements.md](./01-requirements.md) | 要件定義書(機能要件・非機能要件・検証環境) |
| 3 | [02-design.md](./02-design.md) | 設計書(構成図・処理フロー・技術要素解説) |
| 4 | [03-build-guide.md](./03-build-guide.md) | 構築手順書(コマンド・出力例つき) |
| 5 | [04-test-plan.md](./04-test-plan.md) | テスト仕様書(正常系・異常系テストケース) |
| 6 | [05-troubleshooting.md](./05-troubleshooting.md) | トラブルシューティング集(Q&A形式) |
| 7 | [src/.github/workflows/deploy.yml](./src/.github/workflows/deploy.yml) | GitHub Actionsワークフロー定義本体(CI/CDパイプライン) |
| 8 | [src/app/index.html](./src/app/index.html) | デプロイ対象のサンプルWebアプリ(HTML) |
| 9 | [src/app/css/style.css](./src/app/css/style.css) | サンプルWebアプリのスタイル |
| 10 | [src/scripts/test.sh](./src/scripts/test.sh) | CI内で実行するテストスクリプト |
| 11 | [src/scripts/deploy.sh](./src/scripts/deploy.sh) | SSH経由でサーバーへ反映するデプロイスクリプト |

## 使用技術・ツール

| 分類 | 技術・コマンド |
|---|---|
| CI/CDサービス | GitHub Actions(YAMLによるワークフロー定義。`on` / `jobs` / `steps`) |
| 機密情報管理 | GitHub Secrets(`${{ secrets.XXX }}`。SSH秘密鍵・接続情報・Webhook URLを管理) |
| 静的解析(CI) | `shellcheck`(シェルスクリプトの構文・書き方チェック) |
| ファイル転送(CD) | `rsync -avz --delete`(SSH経由の差分同期) |
| SSH | `ssh-keygen`(公開鍵認証用の鍵ペア生成)、`ssh -i` / `-o StrictHostKeyChecking` |
| 通知 | `curl`によるSlack Incoming Webhook連携(=あらかじめ発行された専用URLにHTTPリクエストを送るだけでメッセージを投稿できる仕組み) |
| ジョブ制御 | `needs`(ジョブの依存関係)、`if`(条件付き実行)、`concurrency`(多重実行の排他制御) |
| 既製Action | `actions/checkout@v4`(GitHub公式。リポジトリのチェックアウト) |
| GitHub CLI | `gh run` / `gh secret` / `gh pr`(ターミナルからのActions操作・確認) |
| Webサーバー(デプロイ先) | nginx(静的ファイルの配信) |
| シェル | Bash(`#!/usr/bin/env bash`、`set -eu`) |
| 検証環境 | GitHub Actionsランナー: `ubuntu-latest` / デプロイ先: Ubuntu Server 22.04 LTS |

## この案件で身につくスキル

- GitHub Actionsのワークフロー定義(`on` / `jobs` / `steps`)を、構文としてだけでなく「なぜこの構造になっているか」から理解して書ける
- `push`・`pull_request`・`workflow_dispatch`といったトリガーの違いと、`branches`によるトリガー範囲の絞り込みを、意図を持って設計できる
- `needs`と`if`を組み合わせ、「テストが通ったものだけをデプロイする」という条件付きのジョブ実行フローを実装できる
- GitHub Secretsを使った機密情報の分離管理ができ、「なぜコードに直接書いてはいけないか」を人に説明できる
- SSH公開鍵認証の仕組み(鍵ペアの生成、`authorized_keys`への登録、パーミッション設定)を理解し、CI専用の鍵を安全に運用できる
- `rsync`によるSSH経由の差分ファイル同期を実装し、`--delete`オプションの意味(べき等性=同じ処理を何度実行しても結果が同じになる性質、の担保)まで理解できる
- `shellcheck`を使った静的解析をCIに組み込み、「実行前にコードの品質をチェックする」という考え方を実践できる
- `concurrency`によるワークフローの排他制御など、実運用を意識した安全性の高いパイプライン設計ができる
- CI(継続的インテグレーション)とCD(継続的デリバリー/デプロイ)の違いを、自分の言葉で説明できる

## 面接でアピールできるポイント(3つ、実際に話すセリフ例つき)

1. **「なぜテストが通ったものだけをデプロイするのか」を、`needs`と`if`の仕組みから説明できる**

   > 「このパイプラインでは、`deploy`ジョブに`needs: test`という指定を付け、さらに`if`で『`main`ブランチへのpushのときだけ』という条件を重ねています。GitHub Actionsのジョブは指定が無いと並列実行されてしまうので、この2つを組み合わせないと『テストが失敗しているのに、デプロイだけは走ってしまう』という事故につながります。依頼内容にあった『テストが成功した場合のみ反映する』という要求を、YAMLのこの2行でどう表現するかを最初に設計した部分です。」

2. **秘密鍵やサーバー情報を、なぜGitHub Secretsに切り出したのかを説明できる**

   > 「SSH秘密鍵や接続先IPをワークフローファイルに直接書いてしまうと、一度コミットした時点でGitの履歴に残り続け、後から削除しても`git log`で復元できてしまいます。特にpublicリポジトリでは、漏えいした鍵を自動収集するボットが実在するため、数分で不正利用されるリスクもあります。そこで、コード(処理内容)と機密情報(値)を完全に分離し、`${{ secrets.DEPLOY_SSH_KEY }}`のようにSecrets経由でのみ値を参照する設計にしました。加えて、デプロイ専用に別のSSH鍵ペアを発行し、個人のログイン用鍵とは分けて運用している点も、被害範囲を最小化する工夫です。」

3. **通知して終わりにせず、失敗の切り分けがしやすいパイプラインを意識して設計した**

   > 「デプロイが失敗する原因は、shellcheckのようなコードの問題なのか、SSH認証の問題なのか、サーバー側の権限の問題なのか、段階によって全く異なります。そこで、`test`ジョブと`deploy`ジョブを明確に分け、どちらで失敗したかがGitHub Actionsの画面から一目で分かるようにしました。さらにSlackへの通知も`if: always()`を使って成功・失敗どちらの場合も必ず送るようにし、`job.status`を見て文言を出し分けています。実際に[04-test-plan.md](./04-test-plan.md)では、SSH鍵未登録・authorized_keys未登録・権限不足など、原因別に異常系のテストケースを分けて用意し、それぞれが想定通りのエラーメッセージで失敗することまで確認しました。」

## 学習時間の目安

| フェーズ | 目安時間 |
|---|---|
| 前提知識のインプット(CI/CDの概念、GitHub Actionsの基本構造、SSH公開鍵認証) | 4〜6時間 |
| デプロイ先サーバーの準備(ユーザー作成・鍵登録・nginx設置) | 2〜3時間 |
| ワークフローYAML・スクリプトの実装 | 5〜7時間 |
| GitHub Secretsの登録・Slack連携の設定 | 2〜3時間 |
| テスト・動作確認(正常系・異常系、pull_requestの挙動確認含む) | 5〜7時間 |
| **合計目安** | **18〜26時間程度**(3〜4日程度) |

案件No.1〜No.5をすでに経験済みでBash・SSH・cron(=指定した時刻・間隔で処理を定期実行するLinuxの仕組み)の基礎に慣れている場合でも、GitHub Actions特有の概念(トリガー・ジョブの依存関係・Secrets)を初めて扱う場合は、下限より長めに見積もっておくとよい。

## 前提知識

- Linuxの基本操作(`cd`/`ls`/`cat`/`vi`(または`nano`)などのファイル操作)ができる
- シェルスクリプトの基礎文法(変数、条件分岐`if`、コマンドの終了コードという概念。理想的には案件No.1〜No.4で扱っておくとスムーズ)
- Gitの基本操作(`clone`/`add`/`commit`/`push`/`branch`)ができ、GitHubアカウントを持っている
- SSHで別サーバーへログインした経験があり、「公開鍵・秘密鍵」という言葉のイメージがある
- YAML形式(インデントで階層を表す設定ファイルの書き方)を、読んだことがある程度でよいので知っている

シェルスクリプトやYAMLを書いたことがなくても、[03-build-guide.md](./03-build-guide.md)の手順を上から順に実行すれば動作確認まで到達できる構成にしている。

## ディレクトリ構成

```text
projects/06-cicd-pipeline/
├── README.md              # 本ファイル(案件概要)
├── 01-requirements.md     # 要件定義書
├── 02-design.md           # 設計書(構成図・処理フロー・技術要素解説)
├── 03-build-guide.md      # 構築手順書
├── 04-test-plan.md        # テスト仕様書
├── 05-troubleshooting.md  # トラブルシューティング集
└── src/                   # 実際に動作するワークフロー・アプリ・スクリプト一式
    ├── .github/
    │   └── workflows/
    │       └── deploy.yml # GitHub Actionsワークフロー定義本体
    ├── app/                # デプロイ対象のサンプルWebアプリ(静的サイト)
    │   ├── index.html
    │   └── css/
    │       └── style.css
    └── scripts/
        ├── test.sh         # CI内で実行するテストスクリプト
        └── deploy.sh        # SSH経由でサーバーへ反映するデプロイスクリプト
```

`src/`配下のファイルは、実際に使う対象のGitHubリポジトリの直下へそのままコピーして使う想定([02-design.md](./02-design.md) 6章参照)。

## 関連ドキュメント

- [01-requirements.md](./01-requirements.md) — 機能要件・非機能要件・検証環境
- [02-design.md](./02-design.md) — システム構成図・処理フロー図・トリガー決定フロー・技術要素解説
- [03-build-guide.md](./03-build-guide.md) — サーバー準備からGitHub Secrets登録、動作確認までの手順
- [04-test-plan.md](./04-test-plan.md) — 正常系・異常系テストケース一覧
- [05-troubleshooting.md](./05-troubleshooting.md) — よくあるエラーと対処法(Q&A形式)
- [src/.github/workflows/deploy.yml](./src/.github/workflows/deploy.yml) — ワークフロー本体(コメント多めで解説付き)
- [src/app/index.html](./src/app/index.html) / [src/app/css/style.css](./src/app/css/style.css) — サンプルWebアプリ
- [src/scripts/test.sh](./src/scripts/test.sh) — CI内で実行するテストスクリプト
- [src/scripts/deploy.sh](./src/scripts/deploy.sh) — デプロイ本体スクリプト(CI・手動実行の両方から共用)
