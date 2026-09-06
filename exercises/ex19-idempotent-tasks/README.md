# ex19: べき等なタスクに書き換える

| 項目 | 内容 |
|---|---|
| ステージ | 5: IaC(Ansible) |
| 難易度 | ★★★★☆ |
| 目安時間 | 60分 |
| 身につく力 | べき等性 / 専用モジュールへの置き換え / changed_when と creates |
| 対応する案件 | [案件No.5 Ansibleによるサーバー初期構築自動化](../../projects/05-ansible-provisioning/README.md) |
| 作業するファイル | `work/tasks.yml` |

---

## 1. どんな場面で必要になるか

Ansible を覚えたての人が必ず通る道があります。**「シェルスクリプトで書いていたコマンドを、そのまま `shell:` モジュールに貼り付ける」** という書き方です。動くには動くので、最初は問題に見えません。

問題が出るのは2回目からです。ある現場では、`echo "PermitRootLogin no" >> /etc/ssh/sshd_config` と書いた Playbook を毎週流していました。半年後、`sshd_config` の末尾には同じ行が26個並んでいました。設定としては一応効いていましたが、誰も中身を信用できないファイルになってしまいました。

さらに困るのが「**どこが変わったのか分からなくなる**」ことです。Ansible は実行のたびに `changed=3` のように「何個の項目を変更したか」を出します。本来なら2回目以降は `changed=0` になるはずで、**`changed` が出たら「何かが変わった=調べるべきこと」** という運用ができます。ところが `shell:` を並べていると毎回 `changed` になるため、この信号がまったく役に立ちません。

この演習では、`shell` / `command` だらけの「悪い例」を、専用モジュールを使った **べき等な** 書き方に直します。案件No.5 の各 Role のタスクは、すべてこの形で書かれています。

---

## 2. この演習で学ぶこと

| 学ぶこと | ひとことで言うと |
|---|---|
| べき等性 | 何度実行しても同じ状態に落ち着く性質。Ansibleの一番大事な考え方 |
| `changed` と `ok` | 変更したら `changed`、すでに望みの状態なら `ok`。2回目は `changed=0` が正常 |
| 専用モジュール | `user` / `file` / `lineinfile` / `service` / `apt` など、状態を宣言するための部品 |
| `shell` / `command` の弊害 | Ansibleが状態を判断できないため、必ず `changed` になる |
| `>>` による追記の事故 | 実行のたびに同じ行が増える。`lineinfile` の `regexp` で防ぐ |
| `changed_when` と `creates` | どうしても `shell` を使うときの、べき等性の付け方 |

### 3分でわかる予備知識

**べき等性(べきとうせい)とは**

**同じ処理を何度実行しても、結果が同じ1つの状態に落ち着く性質**のことです。英語では idempotency と言います。

```bash
mkdir /opt/app        # 2回目はエラー。べき等ではない
mkdir -p /opt/app     # 2回目も成功して結果は同じ。べき等
```

Ansible の専用モジュールは、実行前に必ず「今どうなっているか」を確認します。すでに望みの状態なら**何もせず `ok`**、違うときだけ変更して `changed` になります。だから安心して何度でも実行できます。

**なぜ `shell` / `command` は毎回 `changed` になるのか**

```yaml
- name: ユーザーを作成する
  ansible.builtin.shell: useradd -m webadmin
```

Ansible から見えるのは「コマンドを実行した」ということだけです。**そのコマンドが何をしたのか、実行前と後で状態が変わったのかを、Ansibleは判断できません**。そのため、安全側に倒して常に `changed` と報告します。加えて `useradd` はユーザーが既にいるとエラー終了するため、2回目の実行でPlaybook全体が止まってしまいます。

同じことを専用モジュールで書くと、こうなります。

```yaml
- name: ユーザーを作成する
  ansible.builtin.user:
    name: webadmin
    state: present     # 「存在する状態にする」
```

`state: present` は命令ではなく **宣言** です。「webadmin というユーザーが存在する状態にしてください」と書いておけば、いなければ作り、いれば何もしません。

**`>>` による追記は2回実行すると壊れる**

```yaml
- name: SSHの設定を追記する
  ansible.builtin.shell: echo "PermitRootLogin no" >> /etc/ssh/sshd_config
```

`>>` は追記です。10回実行すれば10行増えます。これを防ぐのが `lineinfile` モジュールです。

```yaml
- name: SSHの設定を追記する
  ansible.builtin.lineinfile:
    path: /etc/ssh/sshd_config
    regexp: "^#?PermitRootLogin"     # この正規表現に一致する行を探す
    line: "PermitRootLogin no"       # 見つかれば置き換え、無ければ末尾に追記
    state: present
```

`regexp` が「同じ設定を書いた行」を見つける目印になります。`^#?PermitRootLogin` は「行頭が `PermitRootLogin`、または `#PermitRootLogin`」という意味で、`#` でコメントアウトされている初期設定も拾えるようにしています。**`regexp` を書き忘れると `lineinfile` でも行が増えていく**ので、必ずセットで書いてください。

**主な置き換え先モジュール**

| やりたいこと | `shell` で書きがちなコマンド | 使うべきモジュール |
|---|---|---|
| ユーザーを作る | `useradd -m webadmin` | `ansible.builtin.user` |
| ディレクトリを作る | `mkdir -p /opt/app` | `ansible.builtin.file` |
| 設定を1行入れる | `echo ... >> file` | `ansible.builtin.lineinfile` |
| サービスを起動する | `systemctl start nginx` | `ansible.builtin.service` |
| パッケージを入れる | `apt-get install -y curl` | `ansible.builtin.apt` |

**どうしても `shell` を使うときの逃げ道**

専用モジュールが存在しない処理もあります。その場合は、自分でべき等性を足します。

```yaml
- name: 設定を検証する(状態を変えないコマンド)
  ansible.builtin.command: nginx -t
  changed_when: false        # 実行はするが「変更した」とは報告しない

- name: アーカイブを展開する(1回だけ実行したい)
  ansible.builtin.shell: tar xzf /tmp/app.tar.gz -C /opt/app
  args:
    creates: /opt/app/bin/start.sh    # このファイルが既にあればタスクを飛ばす
```

`changed_when: false` は「このコマンドは状態を変えない」という宣言、`creates:` は「この成果物ができていたら実行しない」という宣言です。この2つを知っているかどうかで、Playbook の質がはっきり変わります。

---

## 3. 課題

`work/tasks.yml` には、`shell` と `command` を乱用した5つのタスクが書かれています。**タスクの数と `- name:` の文言はそのままに**、中身を専用モジュールへ書き換えてください。TODO のコメント行は消してください。

### 書き換えの対応表

| # | タスク名 | 書き換え前 | 書き換え後のモジュールと引数 |
|---|---|---|---|
| 1 | ユーザーを作成する | `shell: useradd -m webadmin` | `ansible.builtin.user`: `name: webadmin` / `shell: /bin/bash` / `create_home: true` / `state: present` |
| 2 | アプリ用ディレクトリを作成する | `shell: mkdir -p /opt/app` | `ansible.builtin.file`: `path: /opt/app` / `state: directory` / `owner: root` / `group: root` / `mode: "0755"` |
| 3 | SSHの設定を追記する | `shell: echo ... >> ...` | `ansible.builtin.lineinfile`: `path: /etc/ssh/sshd_config` / `regexp: "^#?PermitRootLogin"` / `line: "PermitRootLogin no"` / `state: present` |
| 4 | nginx を起動する | `command: systemctl start nginx` | `ansible.builtin.service`: `name: nginx` / `state: started` / `enabled: true` |
| 5 | curl をインストールする | `shell: apt-get install -y curl` | `ansible.builtin.apt`: `name: curl` / `state: present` |

### 仕様

採点では次の項目を確認します。

| No. | 条件 | 期待する動作 |
|---|---|---|
| 1 | 雛形の TODO | `TODO` を含む行が1行も残っていない。雛形の冒頭にある案内文の行も消す |
| 2 | インデント | タブ文字を使わず、半角スペースだけでインデントする |
| 3 | タスクの数 | 行頭の `- name:` がちょうど5つ |
| 4 | `shell` の追放 | `shell` モジュールを1つも使っていない |
| 5 | `command` の追放 | `command` モジュールを1つも使っていない |
| 6 | タスク1 | `ansible.builtin.user:` |
| 7 | タスク2 | `ansible.builtin.file:` |
| 8 | タスク2の状態 | `state: directory` |
| 9 | タスク3 | `ansible.builtin.lineinfile:` |
| 10 | タスク3の目印 | `regexp: "^#?PermitRootLogin"` |
| 11 | タスク4 | `ansible.builtin.service:` |
| 12 | タスク4の起動 | `state: started` |
| 13 | タスク4の自動起動 | `enabled: true` |
| 14 | タスク5 | `ansible.builtin.apt:` |
| 15 | あるべき状態の宣言 | `state: present` |
| 16 | YAMLの書式 | YAMLとして構文エラーなく読み込める |

上の表の文字列は、**そのままの綴り・大文字小文字・半角スペースの位置**で採点します。No.4 と No.5 は、`ansible.builtin.shell:` と `shell:` のどちらの書き方も残っていないことを確認します。**タスク1の `shell: /bin/bash` は `user` モジュールの引数なので消さないでください**(モジュール名ではなく引数なので、採点でも区別しています)。

対応表に出てくる `name` `path` `owner` `group` `mode` `line` `create_home` は採点対象ではありませんが、実務では必ず書くものなので一緒に書いてください。

### 書き換えの形

1つのタスクは「説明 → モジュール → 引数」の3段で書きます。

```text
- name: ユーザーを作成する
  ansible.builtin.???:
    ???: ???
    ???: ???
```

- `- name:` は行頭から書く
- モジュール名は `- name:` の `name` と同じ深さ、つまり半角スペース2つ下げる
- モジュールの引数は、モジュール名よりさらに2スペース深くする
- `mode` のような数字で始まる値は `"0755"` のようにクォートで囲む

---

## 4. やり方

```bash
# 1. exercises ディレクトリに移動する
cd exercises

# 2. 編集する(エディタは vim でも nano でも VS Code でもよい)
nano ex19-idempotent-tasks/work/tasks.yml

# 3. shell / command が残っていないか探す(何も出なければ成功)
grep -nE '^[[:space:]]{0,3}(ansible\.builtin\.)?(shell|command):' \
    ex19-idempotent-tasks/work/tasks.yml

# 4. YAMLとして読めるか手元で確かめる(何も表示されなければ成功)
python3 -c 'import yaml,sys; yaml.safe_load(open(sys.argv[1]))' \
    ex19-idempotent-tasks/work/tasks.yml

# 5. 採点する
./check.sh 19
```

この演習では Ansible をインストールする必要はありません。サーバーに接続することも、`ansible-playbook` を実行することもありません。**書いたYAMLの中身だけ**を採点します。

---

## 5. ヒント

自力で20分考えてから開いてください。段階的に答えに近づくよう3段階に分けています。

<details>
<summary>ヒント1: 書き換えの考え方</summary>

**「どう実行するか」を消して、「どうなっていてほしいか」だけを残す**、と考えると迷いません。

| 元のコマンド | 消える情報 | 残る情報 |
|---|---|---|
| `useradd -m webadmin` | `useradd` という手順、`-m` というオプション | webadmin が存在し、ホームがある |
| `mkdir -p /opt/app` | `mkdir` という手順 | /opt/app がディレクトリとして存在する |
| `systemctl start nginx` | `systemctl` という手順 | nginx が起動している |

残った「状態」を、モジュールの引数として書き並べたものが答えです。手順(コマンド名やオプション)は1文字も書きません。

`-m`(ホームを作る)のようなオプションが持っていた意味は、モジュール側の引数(`create_home: true`)に置き換わります。オプションを消すのではなく、**言い換える**のがコツです。

</details>

<details>
<summary>ヒント2: 1つ書いてみる</summary>

タスク2(ディレクトリ作成)を例にすると、こうなります。

```yaml
- name: アプリ用ディレクトリを作成する
  ansible.builtin.file:
    path: /opt/app
    state: directory
    owner: root
    group: root
    mode: "0755"
```

ポイントは3つです。

- `ansible.builtin.file:` の行は**値を書かず、コロンで終える**。引数を下にぶら下げるため
- 引数はモジュール名より**2スペース深く**する
- `state: directory` が「ディレクトリとして存在する状態にする」という宣言。ファイルにしたいときは `state: touch`、消したいときは `state: absent` に変えるだけでよい

同じ形で残り4つも書けます。モジュール名と引数は「3. 課題」の対応表にすべて載っています。

</details>

<details>
<summary>ヒント3: つまずきやすい2つのタスク</summary>

**タスク1のワナ**: `user` モジュールには `shell:` という引数があります。これは「そのユーザーのログインシェル」を指定するもので、`shell` モジュールとは**まったくの別物**です。

```yaml
- name: ユーザーを作成する
  ansible.builtin.user:
    name: webadmin
    shell: /bin/bash        # これは引数なので消さない
    create_home: true
    state: present
```

採点では「モジュールとして使われている `shell:`」だけを禁止しているので、この行は残して大丈夫です。

**タスク3のワナ**: `lineinfile` は `regexp` を書かないと、`line` と完全一致する行が無い限り追記してしまいます。`regexp` は「同じ設定を書いた行を見つけるための目印」です。

```yaml
- name: SSHの設定を追記する
  ansible.builtin.lineinfile:
    path: /etc/ssh/sshd_config
    regexp: "^#?PermitRootLogin"
    line: "PermitRootLogin no"
    state: present
```

`^#?PermitRootLogin` の `#?` は「`#` があってもなくてもよい」という意味です。コメントアウトされた初期設定を見つけて、そのまま置き換えられるようにしています。

</details>

---

## 6. よくあるつまずき

| 症状 | 原因と対処 |
|---|---|
| 2回目の実行で `changed` が出続ける | `shell` / `command` が残っている。「4. やり方」の手順3のコマンドで探す |
| `/etc/ssh/sshd_config` に同じ行が増えていく | `lineinfile` に `regexp` を書いていない。`line` だけでは既存行を見つけられない |
| `useradd: user 'webadmin' already exists` | まだ `shell: useradd ...` のまま。`user` モジュールに書き換える |
| `has no attribute 'state'` のようなエラー | 引数のインデントが浅く、モジュールの中ではなくタスク直下のキーになっている |
| ディレクトリの権限が `--w----r-T` になる | `mode: 0755` とクォート無しで書いた。`mode: "0755"` と囲む |
| `Unsupported parameters for (user) module` | 引数名の綴り違い。`create_home` を `createhome` と書いていないか確認する |

`./check.sh 19` が失敗したときは、**「期待」と「実際」の差分**を必ず読んでください。どの行が足りないかがそのまま書かれています。

---

## 7. 発展課題(採点対象外)

余裕がある人向けの追加課題です。実務では「もう一歩の気配り」が評価されます。

1. タスク3の `lineinfile` に `validate: "/usr/sbin/sshd -t -f %s"` を足す。これが何を防ぐための指定か、案件No.5 の `roles/users/tasks/main.yml` のコメントを読んで自分の言葉でまとめる
2. `ansible.builtin.apt` を `ansible.builtin.package` に変えると何が変わるか調べる(Ubuntu以外でも動くようになる代わりに、apt固有の引数が使えなくなる)
3. 「専用モジュールが無い処理」を1つ想像し、`changed_when` と `creates` を使ってべき等に書く練習をする(例: 手元のtar.gzを展開する、初回だけデータベースを初期化する)

---

## 8. この演習と案件のつながり

案件No.5 のタスクは、すべてこの演習と同じ方針で書かれています。

- `user` モジュールでのユーザー作成と `lineinfile` でのsshd設定 → [`roles/users/tasks/main.yml`](../../projects/05-ansible-provisioning/src/roles/users/tasks/main.yml)
- `file` モジュールでのディレクトリ作成と権限指定 → [`roles/nginx/tasks/main.yml`](../../projects/05-ansible-provisioning/src/roles/nginx/tasks/main.yml)
- どうしても `command` を使う場面での `changed_when: false` → [`roles/nginx/handlers/main.yml`](../../projects/05-ansible-provisioning/src/roles/nginx/handlers/main.yml) の設定検証タスク
- べき等性の確認手順(2回続けて実行し `changed=0` になることを見る)→ 同案件の [04-test-plan.md](../../projects/05-ansible-provisioning/04-test-plan.md)
- 「宣言的に書く」という考え方は、次のステージのCI/CD設定ファイルにもそのまま続きます

次は [ex20: GitHub Actionsワークフローを書く](../ex20-actions-workflow/README.md) に進んでください。
