# automation

**未経験からサーバー構築エンジニアを目指す人のための、自動化ツール構築「案件パック」型ポートフォリオ**

Linuxサーバーの運用・構築業務でよくある「手作業のミス」「対応漏れ」「属人化」といった課題を、実在しそうな中小企業からの依頼(架空の設定)という体裁で自動化する、全6件の疑似案件を収録したリポジトリです。

## このポートフォリオのコンセプト

未経験からのインフラ・サーバー構築エンジニア転職では、「何を勉強したか」よりも「何を作れるか」が評価されがちです。とはいえ実務経験がない状態では、実際の案件経験を示すことができません。

そこで本ポートフォリオは、次の3つを意識して作られています。

- **「案件」として作る**: 単なる技術のお試し実装ではなく、「どんな会社の、どんな課題に対して、なぜこの技術を選んだか」という依頼背景・要件定義から始める。実務のプロジェクトに近い流れを体験・証明する。
- **ドキュメント一式を揃える**: 要件定義書・設計書(Mermaid図つき)・構築手順書・テスト仕様書・トラブルシューティング集まで、実務で求められる成果物の型を各案件で統一して作成する。
- **実際に動かして検証する**: すべてのスクリプト・設定ファイルは、Ubuntu Serverなどの実機相当の環境で動作確認済み。「動くはず」ではなく「動くことを確認した」状態で公開している。

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

## 学習の進め方(概要)

No.1から順番に取り組むことを推奨します。理由は次のとおりです。

1. **No.1〜No.4はBashシェルスクリプトを共通基盤とし、扱う概念が段階的に積み上がる構成になっている**(ユーザー管理 → cron定期実行 → 常駐監視 → 複数台監視、の順で難易度が上がる)
2. **No.5(Ansible)はNo.1〜4で学んだLinux操作の知識を前提に、それを「コード化・自動適用する」という一段上の視点を学ぶ**
3. **No.6(CI/CD)は全案件の集大成として、GitHubを起点にテスト・デプロイまで自動化する、最もスコープの広いテーマ**

前提知識マップ・案件ごとの学習時間目安・修了後に学ぶとよい発展トピック(Terraform、Docker/Kubernetes、クラウド資格など)は、[docs/02-learning-roadmap.md](docs/02-learning-roadmap.md)にまとめています。

## リポジトリ構成

```text
automation/
├── README.md                      # 本ファイル(ポートフォリオ全体の入口)
├── LICENSE
├── docs/                           # ポートフォリオ全体に関わる横断ドキュメント
│   ├── 01-portfolio-guide.md       # 活用ガイド(面接・職務経歴書での見せ方)
│   ├── 02-learning-roadmap.md      # 学習ロードマップ
│   ├── 03-glossary.md              # 初心者向け用語集
│   └── 04-environment-setup.md     # 検証環境構築ガイド
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

- **転職・就職活動中の方**: 面接での説明の仕方、職務経歴書への書き方、GitHubリポジトリの見せ方のコツをまとめています。
- **採用担当者・面接官の方**: 各案件のREADME.md冒頭に「想定依頼元・背景」「依頼内容(要求仕様)」を記載しているため、まずはNo.4またはNo.5あたりの[README.md](projects/04-server-health-check/README.md)をご覧いただくと、案件の粒度が伝わりやすいかと思います。

## 関連ドキュメント一覧

| ドキュメント | 内容 |
|---|---|
| [docs/01-portfolio-guide.md](docs/01-portfolio-guide.md) | ポートフォリオ活用ガイド(面接・職務経歴書・GitHubでの見せ方) |
| [docs/02-learning-roadmap.md](docs/02-learning-roadmap.md) | 学習ロードマップ(取り組み順序・前提知識・学習時間目安・発展トピック) |
| [docs/03-glossary.md](docs/03-glossary.md) | 初心者向け用語集(全案件共通、40語以上) |
| [docs/04-environment-setup.md](docs/04-environment-setup.md) | 検証環境構築ガイド(VirtualBox/クラウド無料枠、基礎コマンド早見表) |

## ライセンス

[MIT License](LICENSE)
