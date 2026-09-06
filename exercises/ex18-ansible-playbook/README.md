# ex18: Playbookを完成させる

| 項目 | 内容 |
|---|---|
| ステージ | 5: IaC(Ansible) |
| 難易度 | ★★★★☆ |
| 目安時間 | 60分 |
| 身につく力 | YAMLの書き方 / play と task の構造 / モジュールと引数 / handlers と notify |
| 対応する案件 | [案件No.5 Ansibleによるサーバー初期構築自動化](../../projects/05-ansible-provisioning/README.md) |
| 作業するファイル | `work/site.yml` |

---

## 1. どんな場面で必要になるか

ex01〜ex17 では「シェルスクリプトで自動化する」やり方を学んできました。しかし、サーバーの初期構築をシェルスクリプトで書くと、すぐに苦しくなります。「すでにnginxが入っていたら?」「設定ファイルがもう置いてあったら?」を全部 `if` で書き分けなければならないからです。

ある会社では、サーバー構築の手順が20ページのWord文書にまとまっていました。担当者が手作業で40項目のコマンドを打ち、1台あたり半日。しかも打ち間違いが起きるため、**同じ手順で作ったはずの3台の設定が微妙に違う**という状態になっていました。原因を調べるだけで1日かかることもあります。

そこで登場するのが **IaC(Infrastructure as Code。インフラの構成をコードとして書き、そのコードを実行して構築する考え方)** です。**Ansible** はその代表的なツールで、「サーバーをどういう状態にしたいか」を YAML という形式のテキストファイルに書きます。このファイルを **Playbook(プレイブック)** と呼びます。手順書がそのまま実行できるコードになるので、何台あっても、何度実行しても同じ状態に揃います。

この演習では、案件No.5 の `site.yml` をぐっと小さくした版を、自分の手で書きます。Ansible本体のインストールは不要です。書いたYAMLの中身だけを採点します。

---

## 2. この演習で学ぶこと

| 学ぶこと | ひとことで言うと |
|---|---|
| YAMLの書き方 | インデント2スペース、`- ` はリスト、`キー: 値`。タブは使えない |
| play と task | 「どのサーバーに何をするか」の1かたまりが play、その中の作業1つが task |
| `become: true` | そのタスクを管理者権限(sudo)で実行する指定 |
| モジュールと引数 | 実際の処理をする部品がモジュール。`ansible.builtin.apt` などの正式名称で書く |
| `state:` の考え方 | 「実行しろ」ではなく「こういう状態にしろ」と書く。だから何度実行しても安全 |
| handlers と notify | 変更があったときだけ後処理(再起動など)を1回だけ動かす仕組み |

### 3分でわかる予備知識

**YAMLの基本**

YAMLは「設定を書くための、見た目がそのまま意味になる形式」です。覚えることは4つだけです。

```yaml
name: web01          # キーと値。コロンの後ろに半角スペースを必ず1つ入れる
port: 80             # 数字はそのまま数値として読まれる
enabled: true        # true / false は真偽値
packages:            # 下にぶら下げると、その中身になる
  - nginx            # 行頭の「- 」はリストの1要素
  - curl
```

**インデントが命です。次の2つを必ず守ってください。**

- インデントは **半角スペース2つ** ずつ深くする
- **タブ文字は使えない**(YAMLの仕様で禁止されています)

エディタの設定で「タブをスペースに変換する」を有効にしておくと事故を防げます。記号もすべて半角です。全角のコロンや全角スペースが混ざると読み込めません。

**Playbook の構造**

Playbook は「play のリスト」です。play は「どのサーバーに、どんな作業をするか」の1かたまりです。

```yaml
---
- name: play の説明          # 「- 」で始まるので、これはリストの1要素
  hosts: webservers          # 対象のホストグループ
  become: true               # 管理者権限で実行する
  tasks:                     # ここから作業のリスト
    - name: タスクの説明
      ansible.builtin.apt:   # 使うモジュール
        name: nginx          # モジュールに渡す引数
        state: present
```

先頭の `---` は「ここからYAML文書が始まる」という区切りです。`hosts` に書く `webservers` は、対象サーバーの一覧ファイル(インベントリ)に書いておいたグループ名です。

**モジュールと `state:`**

Ansible の実際の処理は **モジュール** という部品が担当します。`ansible.builtin.apt` のように、`ansible.builtin.` から始まる正式名称(FQCN: Fully Qualified Collection Name)で書くのが現在の推奨です。

```yaml
ansible.builtin.apt:
  name: nginx
  state: present     # 「入っている状態にする」
```

ここが Ansible の一番大事な考え方です。`state: present` は **「インストールしろ」という命令ではなく「入っている状態にしろ」という宣言** です。すでに入っていれば何もしません。だから何度実行しても壊れません。この性質を **べき等性(べきとうせい)** と呼びます。詳しくは次の ex19 で扱います。

**handlers と notify**

設定ファイルを配り直したときだけサービスを再起動したい、というのはよくある要件です。毎回再起動すると、そのたびに一瞬アクセスできない時間が生まれるからです。

```yaml
    - name: 設定ファイルを配置する
      ansible.builtin.template:
        src: nginx.conf.j2
        dest: /etc/nginx/nginx.conf
      notify: nginx を再起動する      # 変更があったときだけ、この名前のハンドラを予約する

  handlers:
    - name: nginx を再起動する        # notify と一字一句同じ名前
      ansible.builtin.service:
        name: nginx
        state: restarted
```

`notify` は「予約」です。実際にハンドラが動くのは **play の全タスクが終わったあと、1回だけ** です。設定を10か所直しても再起動は1回で済みます。**`notify` に書く文字列と、`handlers` の `name` は一字一句同じ**でなければ呼ばれません。ここは初心者が最もハマるところです。

**`mode: "0644"` をクォートで囲む理由**

```yaml
mode: "0644"     # 正しい
mode: 0644       # 危険
```

クォートを付けないと、YAMLは `0644` を **10進数の644** として読み込みます。パーミッションは8進数なので、意図とまったく違う権限になってしまいます。**数字で始まる値、特に `mode` は必ずクォートで囲む**と覚えてください。

**`--syntax-check` と `--check`**

実サーバーに流す前の2段構えの安全確認です。この演習では実行しませんが、名前と役割は覚えてください。

```bash
ansible-playbook -i inventory/hosts.ini site.yml --syntax-check
# → YAMLとPlaybookの書式だけを検査する。サーバーには一切さわらない

ansible-playbook -i inventory/hosts.ini site.yml --check --diff
# → ドライラン。「何が変わるか」だけを表示し、実際には変更しない
```

---

## 3. 課題

`work/site.yml` を編集し、次の仕様を満たす Playbook を完成させてください。TODO のコメント行は消してください。

### 仕様

| No. | 条件 | 期待する動作 |
|---|---|---|
| 1 | 雛形の TODO | `TODO` を含む行が1行も残っていない。雛形の冒頭にある案内文の行も消す |
| 2 | インデント | タブ文字を使わず、半角スペースだけでインデントする |
| 3 | 対象ホスト | `hosts: webservers` |
| 4 | 権限昇格 | `become: true` |
| 5 | 変数の置き場 | `vars:` |
| 6 | 変数 | `nginx_port: 80` |
| 7 | タスクの置き場 | `tasks:` |
| 8 | タスク1のモジュール | `ansible.builtin.apt:` |
| 9 | タスク1の状態 | `state: present` |
| 10 | タスク2のモジュール | `ansible.builtin.template:` |
| 11 | タスク2の配置先 | `dest: /etc/nginx/nginx.conf` |
| 12 | タスク2の権限 | `mode: "0644"`(クォートで囲む。シングルクォートでも可) |
| 13 | タスク2の通知 | `notify: nginx を再起動する` |
| 14 | タスク3のモジュール | `ansible.builtin.service:` |
| 15 | タスク3の起動 | `state: started` |
| 16 | タスク3の自動起動 | `enabled: true` |
| 17 | ハンドラの置き場 | `handlers:` |
| 18 | ハンドラの動作 | `state: restarted` |
| 19 | 名前の一致 | `notify:` の値と `handlers` の `- name:` が、まったく同じ文字列 `nginx を再起動する` になっている |
| 20 | YAMLの書式 | YAMLとして構文エラーなく読み込める |

上の表の文字列は、**そのままの綴り・大文字小文字・半角スペースの位置**で採点します。`キー: 値` のコロンの後ろには半角スペースを1つ入れてください。

### 完成イメージ / 出力フォーマット

完成した `site.yml` は次の形になります。`???` の部分を仕様表のとおりに埋めてください。`src` `owner` `group` `update_cache` は採点対象ではありませんが、実務では必ず書くものなので一緒に書いてください。

```text
---
- name: Webサーバーの初期設定
  hosts: ???
  become: ???
  vars:
    ???: ???
  tasks:
    - name: nginx をインストールする
      ansible.builtin.apt:
        name: nginx
        state: ???
        update_cache: true

    - name: 設定ファイルを配置する
      ansible.builtin.template:
        src: nginx.conf.j2
        dest: ???
        owner: root
        group: root
        mode: ???
      notify: ???

    - name: nginx を起動し自動起動を有効にする
      ansible.builtin.service:
        name: nginx
        state: ???
        enabled: ???
  handlers:
    - name: ???
      ansible.builtin.service:
        name: nginx
        state: ???
```

インデントの深さは次のルールで決まります。迷ったら上の形をそのまま真似してください。

- `- name:` の `-` は play の中の2文字目、つまり `hosts` などと同じ深さから始まる
- タスクの中身(モジュール名や `notify`)は `name` と同じ深さに揃える
- モジュールの引数は、モジュール名よりさらに2スペース深くする
- `handlers:` は `tasks:` と同じ深さに書く

---

## 4. やり方

```bash
# 1. exercises ディレクトリに移動する
cd exercises

# 2. 編集する(エディタは vim でも nano でも VS Code でもよい)
nano ex18-ansible-playbook/work/site.yml

# 3. タブが混ざっていないか探す(何も表示されなければタブは無い)
grep -n "$(printf '\t')" ex18-ansible-playbook/work/site.yml

# 4. YAMLとして読めるか手元で確かめる(何も表示されなければ成功)
python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' \
    ex18-ansible-playbook/work/site.yml

# 5. 採点する
./check.sh 18
```

この演習では Ansible をインストールする必要はありません。サーバーに接続することも、`ansible-playbook` を実行することもありません。**書いたYAMLの中身だけ**を採点します。

---

## 5. ヒント

自力で20分考えてから開いてください。段階的に答えに近づくよう3段階に分けています。

<details>
<summary>ヒント1: どこに何を書くかの考え方</summary>

Playbook は「入れ子の箱」だと考えると迷いません。

- 一番外側の箱 = **play**。「どのサーバーに、どの権限で」を書く → `hosts` / `become` / `vars`
- play の中の箱 = **tasks**。「何をするか」を上から順に並べる
- タスクの中の箱 = **モジュールと引数**。「どの部品に、どんな値を渡すか」
- play の中のもう1つの箱 = **handlers**。「呼ばれたときだけ動く後処理」

`hosts` `become` `vars` `tasks` `handlers` は**すべて同じ深さ**に並びます。ここがずれていると「そんなキーは知らない」というエラーになります。

</details>

<details>
<summary>ヒント2: タスク1つ分の書き方</summary>

タスクは必ず「説明 → モジュール → 引数」の3段で書きます。

```yaml
  tasks:
    - name: nginx をインストールする
      ansible.builtin.apt:
        name: nginx
        state: present
        update_cache: true
```

- `- name:` の `- ` は「これはリストの1要素です」という印
- `ansible.builtin.apt:` は行末がコロンで終わり、値は書かない。引数を下にぶら下げるため
- 引数はモジュール名より2スペース深くする

`notify:` はモジュールの引数ではなく **タスク自身の設定** なので、モジュール名と同じ深さに書きます。ここを1段深く書いてしまうのがよくある間違いです。

</details>

<details>
<summary>ヒント3: 全体の骨組み</summary>

```yaml
---
- name: Webサーバーの初期設定
  hosts: ??????????
  become: ????

  vars:
    nginx_port: ??

  tasks:
    - name: nginx をインストールする
      ansible.builtin.apt:
        # name / state / update_cache

    - name: 設定ファイルを配置する
      ansible.builtin.template:
        # src / dest / owner / group / mode
      notify: ここに下のハンドラと同じ名前を書く

    - name: nginx を起動し自動起動を有効にする
      ansible.builtin.service:
        # name / state / enabled

  handlers:
    - name: notify と同じ名前
      ansible.builtin.service:
        # name / state
```

値は仕様表の No.3〜19 にそのまま書いてあります。写すだけでなく、**`state: present` と `state: started` と `state: restarted` が何を意味するか**を「2. この演習で学ぶこと」で確認しながら書いてください。

</details>

---

## 6. よくあるつまずき

| 症状 | 原因と対処 |
|---|---|
| `found character '\t' that cannot start any token` | インデントにタブを使っている。半角スペース2つに直す。`grep -n "$(printf '\t')" ファイル名` でタブのある行を探せる |
| `mapping values are not allowed in this context` | コロンの後ろに半角スペースが無い(`hosts:webservers`)、または値の中にコロンが入っている |
| `did not find expected key` / `bad indentation` | インデントの深さが揃っていない。同じ階層のキーは1文字もずれてはいけない |
| ハンドラが動かない | `notify` の文字列と `handlers` の `name` が違う。全角スペースや句読点の違いに注意する |
| パーミッションが `--w----r-T` のような変な値になる | `mode: 0644` とクォート無しで書いた。`mode: "0644"` と囲む |
| `'tasks' is not a valid attribute for a Play` | `tasks:` のインデントが `hosts:` とずれている。play 直下のキーはすべて同じ深さ |
| 何も実行されない | `hosts:` に書いたグループがインベントリに無い。実サーバーでは `ansible-inventory --graph` で確認する |

`./check.sh 18` が失敗したときは、**「期待」と「実際」の差分**を必ず読んでください。どの行が足りないかがそのまま書かれています。

---

## 7. 発展課題(採点対象外)

余裕がある人向けの追加課題です。実務では「もう一歩の気配り」が評価されます。

1. `vars` の `nginx_port` を実際に使う `nginx.conf.j2` を書いてみる(テンプレートの中では `{{ nginx_port }}` と書くと値に置き換わる)
2. ハンドラを2つに分け、「設定ファイルの文法チェック」→「再起動」の順で動くようにする(案件No.5 の `roles/nginx/handlers/main.yml` が参考になります)
3. `ansible.builtin.apt` は Debian/Ubuntu 専用です。`ansible.builtin.package` に変えると何が変わるか、`when: ansible_facts['os_family'] == "Debian"` と組み合わせる場合とどちらが良いかを調べる

---

## 8. この演習と案件のつながり

案件No.5 の Playbook が、この演習の完成形にあたります。

- play の骨格(`hosts` / `become` / Roleの呼び出し)→ [`site.yml`](../../projects/05-ansible-provisioning/src/site.yml)
- パッケージ導入・テンプレート配置・サービス起動の3点セット → 同案件の [`roles/nginx/tasks/main.yml`](../../projects/05-ansible-provisioning/src/roles/nginx/tasks/main.yml)
- `notify` から呼ばれるハンドラの書き方 → 同案件の [`roles/nginx/handlers/main.yml`](../../projects/05-ansible-provisioning/src/roles/nginx/handlers/main.yml)
- 変数を1か所にまとめる考え方 → 同案件の `group_vars/` と各Roleの `defaults/main.yml`
- 案件の実物では、タスクを **Role** という単位に分けて再利用できるようにしています。この演習で1枚のPlaybookを書けるようになってから読むと、Roleが「タスクの引っ越し先」にすぎないことが分かります

次は [ex19: べき等なタスクに書き換える](../ex19-idempotent-tasks/README.md) に進んでください。
