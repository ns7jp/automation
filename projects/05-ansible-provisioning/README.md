# 案件No.5: Ansibleによるサーバー初期構築自動化(IaC)

## 難易度

★★★★☆(中級〜上級)

これまでの案件(No.1〜4)はシェルスクリプトとcron/systemdが中心だったが、今回は「Ansible」という構成管理ツールを使い、複数台のサーバー構築そのものを自動化・標準化する。YAMLの記法、Role(役割)ごとのコード分割、べき等性(=何度実行しても安全で結果が同じになる性質)、SSH接続の仕組みなど、覚える概念の量が一段増えるため、これまでの案件よりも難易度を高めに設定している。ただし、1つ1つの概念は難しいものではなく、順を追って理解すれば必ず身につく内容になっている。

## 想定依頼元・背景

株式会社サンプル商事(架空の企業)。案件No.1〜4を通じてLinuxサーバーの運用改善を支援してきたが、新しいサービスを立ち上げるたびに「また手作業でNginxを1から設定する」という状態が続いていた。

ある案件では設定ファイルの記述ミスでポート80が開いておらず公開が半日遅れ、別の案件では作業者によって構築にかかる時間が2時間だったり半日だったりとばらついていた。この「属人化」と「手作業ゆえのミス」を解消するため、「サーバー構築の手順そのものをコード化して、誰が実行しても同じ結果になるようにしてほしい」という依頼が来た、という想定でこの案件は設計されている。これはInfrastructure as Code(IaC。「インフラの構成をコードとして記述し、管理する」という考え方)を実際の案件に導入する、というテーマになっている。

## 依頼内容(要求仕様)

- AnsibleのPlaybook(=実行する作業手順をYAMLで記述したファイル)を使い、まっさらなLinuxサーバーに対して以下を自動構築できること
  - Nginxのインストールと基本設定(ポート80で静的ページを公開)
  - ファイアウォール(firewalldまたはufw)でHTTP/HTTPS/SSHのみ許可
  - 作業用一般ユーザーの作成とSSH公開鍵の配置(パスワード認証は無効化)
  - タイムゾーンをAsia/Tokyoに設定
  - Inventoryファイル(=対象サーバーの一覧を書いたファイル)で対象サーバーを指定し、1コマンド(`ansible-playbook`)で実行できること
- 何度実行しても同じ結果になる(べき等性)ことを確認できるようにすること(`ansible-playbook --check`の活用を含む)
- 役割ごとにRole分割してコードを整理すること(common用Role、nginx用Role等)

詳細は [01-requirements.md](./01-requirements.md) を参照。

## 成果物一覧

| ファイル | 内容 |
|---|---|
| `README.md` | 本ファイル。案件概要 |
| `01-requirements.md` | 要件定義書(機能要件・非機能要件・検証環境) |
| `02-design.md` | 設計書(システム構成図・処理フロー・技術要素解説) |
| `03-build-guide.md` | 構築手順書(コマンドと出力例つき) |
| `04-test-plan.md` | テスト仕様書(正常系・異常系のテストケース) |
| `05-troubleshooting.md` | トラブルシューティング集(Q&A形式) |
| `src/ansible.cfg` | Ansibleの動作設定ファイル |
| `src/requirements.yml` | 使用するAnsible Collectionの定義 |
| `src/inventory/hosts.ini` | 対象サーバーの一覧(Inventory) |
| `src/group_vars/` | グループ単位の変数定義 |
| `src/files/` | SSH公開鍵ファイルの配置場所(サンプルファイルを同梱) |
| `src/site.yml` | 全体の入口となるPlaybook |
| `src/roles/common/` | 共通初期設定(パッケージ・タイムゾーン)のRole |
| `src/roles/users/` | 作業用ユーザー作成・SSH鍵配置・パスワード認証無効化のRole |
| `src/roles/firewall/` | ファイアウォール(ufw/firewalld)設定のRole |
| `src/roles/nginx/` | Nginxインストール・設定・静的ページ公開のRole |
| `src/verify.sh` | 構築後の要件充足を自動チェックする検証スクリプト |

## 使用技術・ツール

- **Ansible**: 構成管理ツール本体(`ansible-core`)。SSH経由でエージェントレス(=対象サーバーに専用の常駐プログラムを入れずに)動作する
- **YAML**: Playbook/Role/変数ファイルの記述フォーマット
- **Inventory**: 対象サーバーの一覧・接続情報を定義するファイル(`inventory/hosts.ini`)
- **Playbook / Role**: 実行内容(タスク)をまとめたファイル、およびそれを役割ごとに分割した構造
- **Handlers**: 変更があったときだけ実行される後処理(サービス再起動など)
- **Jinja2テンプレート**: 変数を埋め込んだ設定ファイルを動的に生成する仕組み(`nginx.conf.j2`)
- **ansible.posix / community.general**: SSH鍵配置・firewalld・ufwなどを扱うためのAnsible Collection(追加モジュール集)
- **ansible-playbook --check / --diff**: 実際には変更せず「何が変わるか」だけを確認するdry run機能
- **Nginx**: Webサーバーソフトウェア
- **ufw / firewalld**: Linuxのファイアウォール制御ツール(OSの系統によって使い分け)
- **OpenSSH**: 公開鍵認証によるリモート接続

## この案件で身につくスキル

- IaC(Infrastructure as Code)の考え方と、手作業運用との違いを説明できる
- YAMLの読み書き(インデントによる階層表現、リスト・辞書の書き方)ができる
- Playbookの基本構造(`hosts` / `tasks` / `handlers` / `roles`)を理解し、自分で1から書ける
- べき等性を意識したタスク設計ができ、`--check`/`--diff`で事前に影響範囲を確認する習慣が身につく
- Roleによるコードの構造化(共通処理と個別処理を分離する設計)ができる
- Jinja2テンプレートを使い、変数によって内容が変わる設定ファイルを生成できる
- SSH公開鍵認証の設定と、パスワード認証を無効化する際の安全な手順(段階的な適用)を理解している
- OSの違い(Debian系/RedHat系)を`ansible_facts`で判定し、処理を分岐させる実装ができる

## 面接でアピールできるポイント(3つ、実際に話すセリフ例つき)

1. **手作業のサーバー構築をAnsibleでコード化し、再現性を担保した経験**
   > 「新規サービス立ち上げのたびに手作業でNginxを構築していた運用を、AnsibleのPlaybookに置き換えました。Inventoryに対象サーバーを追加してコマンドを1つ実行するだけで、Nginx・ファイアウォール・ユーザー作成・タイムゾーン設定まで、誰が実行しても同じ結果になる状態を作れます。手順書を人が目で追って作業する方式に比べ、設定ミスによる公開遅延のリスクを構造的に減らせる点を意識しました。」

2. **べき等性を理解した上でのタスク設計と、dry runによる事前確認の習慣**
   > 「Ansibleの各タスクは、既に望ましい状態であれば何もしない、というべき等性を持たせる必要があると理解した上で実装しました。本番適用の前に必ず`ansible-playbook --check --diff`でdry runを行い、意図しない変更が含まれていないかを確認してから実行する、という運用フローを自分の中で徹底しています。」

3. **『鍵を掛ける前に鍵が開くことを確認する』という安全な運用設計**
   > 「SSHのパスワード認証を無効化するタスクには`ssh_lockdown`というタグを付け、まず一般ユーザー作成と鍵配置だけを先に実行し、鍵ログインが成功することを別ターミナルで確認してから、パスワード認証とrootログインを無効化する、という2段階の適用フローを設計しました。自動化は速く進められる分、1つの実行ミスでサーバーに入れなくなるリスクもあるため、そこに配慮した経験として話せます。」

## 学習時間の目安

| フェーズ | 時間目安 |
|---|---|
| 前提知識のインプット(YAML/SSH鍵認証/IaCの考え方) | 3〜4時間 |
| Ansibleの基本操作の習得(Inventory・ad-hocコマンド・Playbookの最小構成) | 3〜4時間 |
| Role分割・Jinja2テンプレート・Handlersの実装 | 4〜6時間 |
| 環境構築・動作確認・べき等性確認・異常系テスト | 4〜5時間 |
| **合計** | **14〜19時間程度** |

案件No.1〜4を経験済みでLinuxコマンド・SSH接続・シェルスクリプトに慣れている場合は、下限に近い時間で完了できる想定。逆にAnsibleに初めて触れる場合は、上限より多く見ておくとよい。

## 前提知識

- Linuxの基本操作(`cd` / `ls` / `chmod` / `systemctl`などのコマンド)
- SSHでリモートサーバーに接続した経験、公開鍵認証の基本(秘密鍵・公開鍵の違い)
- YAMLの基礎(スペースによるインデントで階層を表す、リストは`-`で書く、といった最低限のルール。詳細は[02-design.md](./02-design.md)で解説)
- Linuxのファイアウォール(ポート・プロトコルの概念)について、大まかなイメージ
- Nginxを手作業で構築した経験があると、今回の自動化のありがたみが理解しやすい(未経験でも本書内で解説するため必須ではない)

## ディレクトリ構成

```text
projects/05-ansible-provisioning/
├── README.md                      # 本ファイル(案件概要書)
├── 01-requirements.md             # 要件定義書
├── 02-design.md                   # 設計書(構成図・処理フロー・技術要素解説)
├── 03-build-guide.md              # 構築手順書
├── 04-test-plan.md                # テスト仕様書
├── 05-troubleshooting.md          # トラブルシューティング集
└── src/                           # 実際に動作するAnsibleプロジェクト一式
    ├── ansible.cfg                # Ansible動作設定
    ├── requirements.yml           # 使用するCollectionの定義
    ├── site.yml                   # 全体の入口となるPlaybook
    ├── verify.sh                  # 構築後の検証スクリプト
    ├── inventory/
    │   └── hosts.ini              # 対象サーバー一覧(Inventory)
    ├── group_vars/
    │   ├── all.yml                # 全ホスト共通の変数
    │   └── webservers.yml         # webserversグループ用の変数
    ├── files/
    │   └── webadmin_id_ed25519.pub.example  # SSH公開鍵ファイルのサンプル
    └── roles/
        ├── common/                # 共通初期設定(パッケージ・タイムゾーン)
        │   ├── defaults/main.yml
        │   └── tasks/main.yml
        ├── users/                 # ユーザー作成・SSH鍵配置・パスワード認証無効化
        │   ├── defaults/main.yml
        │   ├── tasks/main.yml
        │   └── handlers/main.yml
        ├── firewall/              # ファイアウォール設定(ufw/firewalld)
        │   ├── defaults/main.yml
        │   └── tasks/
        │       ├── main.yml
        │       ├── Debian.yml
        │       └── RedHat.yml
        └── nginx/                 # Nginxインストール・設定・静的ページ公開
            ├── defaults/main.yml
            ├── tasks/main.yml
            ├── handlers/main.yml
            └── templates/
                ├── nginx.conf.j2
                └── index.html.j2
```

## 関連ドキュメント

- [01-requirements.md](./01-requirements.md) — 要件定義書
- [02-design.md](./02-design.md) — 設計書
- [03-build-guide.md](./03-build-guide.md) — 構築手順書
- [04-test-plan.md](./04-test-plan.md) — テスト仕様書
- [05-troubleshooting.md](./05-troubleshooting.md) — トラブルシューティング集
- [src/site.yml](./src/site.yml) — 全体の入口となるPlaybook
- [src/inventory/hosts.ini](./src/inventory/hosts.ini) — 対象サーバー一覧
- [src/roles/common/](./src/roles/common/) — 共通初期設定Role
- [src/roles/users/](./src/roles/users/) — ユーザー・SSH鍵Role
- [src/roles/firewall/](./src/roles/firewall/) — ファイアウォールRole
- [src/roles/nginx/](./src/roles/nginx/) — NginxRole
- [src/verify.sh](./src/verify.sh) — 検証スクリプト
