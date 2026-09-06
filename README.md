# automation

**未経験からサーバー構築エンジニアを目指す人のための、自動化ツール構築「案件パック」型ポートフォリオ**

Linuxサーバーの運用・構築業務でよくある「手作業のミス」「対応漏れ」「属人化」といった課題を、実在しそうな中小企業からの依頼(架空の設定)という体裁で自動化する、全6件の疑似案件を収録したリポジトリです。

さらに、その6案件を「読んで分かる」から「自分で書ける」に変えるための、**自動採点つき演習パック(全21演習)** を [exercises/](exercises/README.md) に収録しています。

## このポートフォリオのコンセプト

未経験からのインフラ・サーバー構築エンジニア転職では、「何を勉強したか」よりも「何を作れるか」が評価されがちです。とはいえ実務経験がない状態では、実際の案件経験を示すことができません。

そこで本ポートフォリオは、次の3つを意識して作られています。

- **「案件」として作る**: 単なる技術のお試し実装ではなく、「どんな会社の、どんな課題に対して、なぜこの技術を選んだか」という依頼背景・要件定義から始める。実務のプロジェクトに近い流れを体験・証明する。
- **ドキュメント一式を揃える**: 要件定義書・設計書(Mermaid図つき)・構築手順書・テスト仕様書・トラブルシューティング集まで、実務で求められる成果物の型を各案件で統一して作成する。
- **実際に動かして検証する**: すべてのスクリプト・設定ファイルは、Ubuntu Serverなどの実機相当の環境で動作確認済み。「動くはず」ではなく「動くことを確認した」状態で公開している。
- **自分の手で書く場を用意する**: 完成品を読むだけでは書けるようにならないため、1演習30〜90分の演習パックを併設。`./check.sh` による自動採点で、独学でも即座に答え合わせができる。

初心者向けの学習リソースとしても使えるよう、専門用語には初出時に一言解説を添え、コマンド例には実行結果のイメージを併記しています。

## 収録案件一覧

| No. | 案件名 | 難易度 | 主な技術 | 学べること(抜粋) | リンク |
|---|---|---|---|---|---|
| 1 | Linuxユーザーアカウント一括作成・管理自動化ツール | ★☆☆☆☆(入門) | Bash / useradd・usermod・groupadd / chpasswd / chage / getopts | シェルスクリプトの基本文法、Linuxアカウント管理コマンド、CSVパース | [projects/01-user-account-automation/README.md](projects/01-user-account-automation/README.md) |
| 2 | 定期バックアップ自動化&世代管理ツール | ★★☆☆☆(初級) | Bash / tar・gzip / find(-mtime) / cron / Slack Webhook / logrotate | cronによる定期実行、tarでのアーカイブ、世代管理、失敗時通知 | [projects/02-backup-automation/README.md](projects/02-backup-automation/README.md) |
| 3 | ログ監視・異常検知アラート通知ツール | ★★★☆☆(初級〜中級) | Bash / tail -F / grep -E / Slack Webhook / jq / systemd | 正規表現によるログ検知、スロットリング設計、systemdでの常駐化 | [projects/03-log-monitoring-alert/README.md](projects/03-log-monitoring-alert/README.md) |
| 4 | サーバー死活監視・障害検知ツール | ★★★☆☆(中級) | Bash / ping / curl / cron / awk | ping・HTTPの2方式監視、状態ファイルによるフラッピング対策、稼働率集計 | [projects/04-server-health-check/README.md](projects/04-server-health-check/README.md) |
| 5 | Ansibleによるサーバー初期構築自動化(IaC) | ★★★★☆(中級〜上級) | Ansible / YAML / Jinja2 / Role構成 / ufw・firewalld / Nginx | IaCの考え方、Playbook/Role設計、べき等性、SSH鍵認証の段階適用 | [projects/05-ansible-provisioning/README.md](projects/05-ansible-provisioning/README.md) |
| 6 | GitHub ActionsによるCI/CD自動デプロイパイプライン構築 | ★★★★★(上級) | GitHub Actions / YAML / GitHub Secrets / shellcheck / rsync / SSH | CI/CDワークフロー設計、Secrets管理、条件付きジョブ実行、静的解析組み込み | [projects/06-cicd-pipeline/README.md](projects/06-cicd-pipeline/README.md) |

難易度は★1つ(入門)〜★5つ(上級)の5段階です。各案件のREADME.mdに、その難易度とした理由も明記しています。

## 手を動かして覚える: 自動化スクリプト演習パック

上記6案件のスクリプトは、完成品として読むぶんには丁寧に解説していますが、**読めることと自分で書けることは別の能力**です。そこで、案件パックの手前に置く練習場として、[exercises/](exercises/README.md) に全21演習の演習パックを用意しました。

| 特徴 | 内容 |
|---|---|
| 1演習=1概念 | 30〜90分で終わる単位に分解。つまずいた原因を自分で切り分けられる |
| 自動採点 | `./check.sh 01` で合否が即座に返る。不合格時は「期待・実際・ヒント」の3点セットを表示 |
| 環境ゼロで始められる | root権限・サーバー・インターネット接続はいずれも不要。Linuxとbashだけで全21演習が動く |
| 安全 | 採点は使い捨ての一時ディレクトリ内で実行。`useradd` や `ping` はダミーに差し替えるため、実環境を一切変更しない |
| 案件と地続き | 各演習に「対応する案件のどの処理か」を明示。ステージを終えるごとに案件本体を読む流れ |

```bash
git clone https://github.com/ns7jp/automation.git
cd automation/exercises
./check.sh --list      # 演習一覧を見る
./check.sh 01          # 最初の演習を採点する
```

演習は6ステージ・21演習で、案件No.1〜No.6に1対1で対応しています。設計の考え方(学習設計・難易度設計・採点システムの設計)は [exercises/docs/01-design.md](exercises/docs/01-design.md) にまとめています。

## 学習の進め方(概要)

**シェルスクリプトを書いた経験がない場合は、まず [exercises/](exercises/README.md) の演習パック(ステージ1: ex01〜ex06、約5時間)から始めてください。** 案件No.1のスクリプトを構成する部品を、1つずつ自分の手で書けるようになります。

案件は No.1から順番に取り組むことを推奨します。理由は次のとおりです。

1. **No.1〜No.4はBashシェルスクリプトを共通基盤とし、扱う概念が段階的に積み上がる構成になっている**(ユーザー管理 → cron定期実行 → 常駐監視 → 複数台監視、の順で難易度が上がる)
2. **No.5(Ansible)はNo.1〜4で学んだLinux操作の知識を前提に、それを「コード化・自動適用する」という一段上の視点を学ぶ**
3. **No.6(CI/CD)は全案件の集大成として、GitHubを起点にテスト・デプロイまで自動化する、最もスコープの広いテーマ**

前提知識マップ・案件ごとの学習時間目安・修了後に学ぶとよい発展トピック(Terraform、Docker/Kubernetes、クラウド資格など)は、[docs/02-learning-roadmap.md](docs/02-learning-roadmap.md)にまとめています。

## リポジトリ構成

```text
automation/
├── README.md                      # 本ファイル(ポートフォリオ全体の入口)
├── LICENSE
├── .github/workflows/              # 演習パックを継続的に検証するCI設定
├── docs/                           # ポートフォリオ全体に関わる横断ドキュメント
│   ├── 01-portfolio-guide.md       # 活用ガイド(面接・職務経歴書での見せ方)
│   ├── 02-learning-roadmap.md      # 学習ロードマップ
│   ├── 03-glossary.md              # 初心者向け用語集
│   └── 04-environment-setup.md     # 検証環境構築ガイド
├── exercises/                      # 演習パック(全21演習・自動採点つき)
│   ├── README.md                   # 演習パックの入口
│   ├── check.sh                    # 自動採点ツール
│   ├── docs/                       # 設計書・はじめかた・カリキュラムマップ等
│   ├── lib/                        # 採点の共通部品(判定関数・スタブ)
│   ├── tools/                      # 静的解析・一覧生成
│   └── exNN-<名前>/                 # 各演習(課題文 + 雛形 + 解答例 + 採点テスト)
└── projects/                       # 案件本体(全6件)
    ├── 01-user-account-automation/
    │   ├── README.md                # 案件概要・アピールポイント
    │   ├── 01-requirements.md       # 要件定義書
    │   ├── 02-design.md             # 設計書(Mermaid図つき)
    │   ├── 03-build-guide.md        # 構築手順書
    │   ├── 04-test-plan.md          # テスト仕様書
    │   ├── 05-troubleshooting.md    # トラブルシューティング集
    │   └── src/                     # 動作検証済みのスクリプト本体
    ├── 02-backup-automation/        # (以下、同様の構成)
    ├── 03-log-monitoring-alert/
    ├── 04-server-health-check/
    ├── 05-ansible-provisioning/
    └── 06-cicd-pipeline/
```

各案件フォルダは同じ構成(README + 01〜05の文書 + src)で統一しているため、1件の読み方を覚えれば残り5件も同じ要領で読めます。

## このポートフォリオの使い方

初めて見る方は、まず[docs/01-portfolio-guide.md](docs/01-portfolio-guide.md)(ポートフォリオ活用ガイド)を確認してください。

- **これから学ぶ方**: [exercises/README.md](exercises/README.md) の演習パックから始めてください。環境準備を含めて1〜2時間で最初の1問が解けます。
- **転職・就職活動中の方**: 面接での説明の仕方、職務経歴書への書き方、GitHubリポジトリの見せ方のコツをまとめています。
- **採用担当者・面接官の方**: 各案件のREADME.md冒頭に「想定依頼元・背景」「依頼内容(要求仕様)」を記載しているため、まずはNo.4またはNo.5あたりの[README.md](projects/04-server-health-check/README.md)をご覧いただくと、案件の粒度が伝わりやすいかと思います。

## 関連ドキュメント一覧

| ドキュメント | 内容 |
|---|---|
| [docs/01-portfolio-guide.md](docs/01-portfolio-guide.md) | ポートフォリオ活用ガイド(面接・職務経歴書・GitHubでの見せ方) |
| [docs/02-learning-roadmap.md](docs/02-learning-roadmap.md) | 学習ロードマップ(取り組み順序・前提知識・学習時間目安・発展トピック) |
| [docs/03-glossary.md](docs/03-glossary.md) | 初心者向け用語集(全案件共通、40語以上) |
| [docs/04-environment-setup.md](docs/04-environment-setup.md) | 検証環境構築ガイド(VirtualBox/クラウド無料枠、基礎コマンド早見表) |
| [exercises/README.md](exercises/README.md) | 演習パックの入口(全21演習の一覧・進め方・採点ツールの使い方) |
| [exercises/docs/01-design.md](exercises/docs/01-design.md) | 演習パック設計書(学習設計・難易度設計・自動採点システムの設計) |
| [exercises/docs/02-getting-started.md](exercises/docs/02-getting-started.md) | 演習パックのはじめかた(環境準備から最初の1問まで) |
| [exercises/docs/03-curriculum-map.md](exercises/docs/03-curriculum-map.md) | カリキュラムマップ(演習・案件・スキルの対応と依存関係) |

## ライセンス

[MIT License](LICENSE)
