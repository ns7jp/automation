# 03. 構築手順書

本手順は、以下2台の「まっさらな」Linuxサーバーが既に起動しており、コントロールノード(作業PC)からrootでSSH鍵ログインできる状態であることを前提に進める(検証環境の詳細は[01-requirements.md](./01-requirements.md)を参照)。

- `web01`: Ubuntu Server 22.04 LTS
- `web02`: AlmaLinux 9.3

以降のコマンドは、断りが無い限り**コントロールノード側**(作業PC)の、このリポジトリの`src/`ディレクトリで実行する想定で記載する。

```bash
cd projects/05-ansible-provisioning/src
```

## Step 0. 前提の確認

```bash
lsb_release -a
```

```text
Distributor ID: Ubuntu
Description:    Ubuntu 22.04.4 LTS
Release:        22.04
Codename:       jammy
```

💡ポイント: これはコントロールノード(作業PC)側の確認。管理対象サーバー(web01/web02)ではなく、Ansibleを実行する側のOSを確認している点に注意。検証環境([01-requirements.md](./01-requirements.md))とズレがないか、最初に確認しておくと後々のトラブルシューティングが楽になる。

## Step 1. コントロールノードにAnsibleをインストールする

```bash
sudo apt update
sudo apt install -y ansible
```

**何をしているか**: Ansible本体(`ansible-core`を含むパッケージ)をコントロールノードにインストールしている。

**なぜ**: Ansibleは「管理対象サーバー」ではなく「コントロールノード(作業PC)」側にインストールする。管理対象サーバー側には専用ソフトのインストールが不要(=エージェントレス)という点が、Ansibleの大きな特徴になっている(詳細は[02-design.md](./02-design.md) 5.8節)。

インストールできたか確認する。

```bash
ansible --version
```

```text
ansible [core 2.16.3]
  config file = None
  configured module search path = ['/home/user/.ansible/plugins/modules', '/usr/share/ansible/plugins/modules']
  ansible python module location = /usr/lib/python3/dist-packages/ansible
  ansible collection location = /home/user/.ansible/collections:/usr/share/ansible/collections
  executable location = /usr/bin/ansible
  python version = 3.10.12 (main, Nov  6 2024, 16:19:19) [GCC 11.4.0]
  jinja version = 3.1.2
  libyaml = True
```

`config file = None`となっているのは、まだ`src/`ディレクトリに移動する前に実行したため。Step 2以降、`src/`ディレクトリ内で実行すると、そこに置いた`ansible.cfg`が自動的に読み込まれるようになる。

## Step 2. 必要なAnsible Collectionをインストールする

```bash
ansible-galaxy collection install -r requirements.yml
```

```text
Starting galaxy collection install process
Process install dependency map
Starting collection install process
Installing 'ansible.posix:1.5.4' to '/home/user/.ansible/collections/ansible_collections/ansible/posix'
ansible.posix:1.5.4 was installed successfully
Installing 'community.general:8.3.0' to '/home/user/.ansible/collections/ansible_collections/community/general'
community.general:8.3.0 was installed successfully
```

**何をしているか**: `requirements.yml`に書かれたCollection(SSH公開鍵管理・ufw・firewalldなどの追加モジュール集)をダウンロードし、コントロールノードにインストールしている。

**なぜ**: `ansible.posix.authorized_key`や`community.general.ufw`といったモジュールは、Ansible本体(`ansible-core`)には含まれていない。このコマンドを実行し忘れると、Playbook実行時に「モジュールが見つからない」エラーになる(詳しくは[05-troubleshooting.md](./05-troubleshooting.md) Q5)。

## Step 3. SSH鍵ペアを作成し、公開鍵ファイルを配置する

作業用一般ユーザー(`webadmin`)がログインに使う鍵ペアを、コントロールノード側で作成する。

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_ansible -C "webadmin@portfolio"
```

```text
Generating public/private ed25519 key pair.
Enter passphrase (empty for no passphrase): 
Enter same passphrase again: 
Your identification has been saved in /home/user/.ssh/id_ed25519_ansible
Your public key has been saved in /home/user/.ssh/id_ed25519_ansible.pub
The key fingerprint is:
SHA256:AbCdEfGhIjKlMnOpQrStUvWxYz0123456789ABCDEFG webadmin@portfolio
```

**何をしているか**: ed25519方式(比較的新しく安全性・速度のバランスが良いとされる鍵の方式)で、秘密鍵・公開鍵のペアを新規作成している。

生成された公開鍵の中身を、Ansibleが読み込むファイルとしてコピーする。

```bash
cp ~/.ssh/id_ed25519_ansible.pub files/webadmin_id_ed25519.pub
cat files/webadmin_id_ed25519.pub
```

```text
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx webadmin@portfolio
```

💡ポイント: `files/webadmin_id_ed25519.pub.example`はサンプルであり、このままでは使えない。実際にこのStepで生成した**自分の公開鍵**の中身を、拡張子`.example`を外したファイル名で配置する必要がある。配置を忘れると、後続のStepで「ファイルが見つからない」というエラーになる(この失敗パターンは[04-test-plan.md](./04-test-plan.md)のTC-15で扱っている)。

## Step 4. Inventoryを編集し、対象サーバーの接続情報を設定する

```bash
vi inventory/hosts.ini
```

`ansible_host`の値を、実際のサーバーのIPアドレスに書き換える。

```ini
[webservers]
web01 ansible_host=203.0.113.10
web02 ansible_host=203.0.113.11

[webservers:vars]
ansible_user=root
ansible_ssh_private_key_file=~/.ssh/id_ed25519_bootstrap
ansible_python_interpreter=/usr/bin/python3
```

**なぜ**: サンプルの`192.0.2.10`/`192.0.2.11`はRFC 5737で予約された「実在しないドキュメント用」のアドレスであり、そのままでは接続できない。`ansible_ssh_private_key_file`には、サーバー作成時に発行された(rootでログインするための)初期鍵のパスを指定する。

> 💡 YAML/INIファイルを編集する際のよくあるミス: `ansible_host=203.0.113.10`のように、キーと値の間に余計な半角スペースを入れないこと(INI形式のInventoryでは`key=value`の`=`前後にスペースを入れるとうまく解釈されないことがある)。YAML側(`group_vars/*.yml`等)を編集する場合は、[02-design.md](./02-design.md) 5.1節のインデントルールを必ず守ること。

## Step 5. 疎通確認(ansible -m ping)

```bash
ansible all -m ansible.builtin.ping
```

```text
web01 | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
web02 | SUCCESS => {
    "changed": false,
    "ping": "pong"
}
```

**何をしているか**: Inventoryに書いた全ホスト(`all`)に対して、`ping`モジュールを実行している。このように、Playbook(YAMLファイル)を書かずに`ansible`コマンドから1つのモジュールをその場で直接実行する使い方を「ad-hocコマンド」と呼ぶ。使い捨ての確認作業や、Step 13(verify.shの実行)・Step 14(設定ドリフトの再現)のような単発の操作に向いている。

💡ポイント: この`ping`はネットワークのICMP ping(`ping`コマンド)とは**別物**。SSH接続 → Pythonの実行 → `pong`という応答を返す、というAnsibleの一連の処理が正しく動くかを確認するモジュール。`"changed": false`となっているのも、「単に接続確認しただけで、サーバーの状態は何も変えていない」ことを表している。

## Step 6. Playbookの構文チェック

サーバーに接続する前に、まずYAMLとしての文法が正しいかを確認する。

```bash
ansible-playbook site.yml --syntax-check
```

```text
playbook: site.yml
```

**何をしているか**: `site.yml`とそこから読み込まれる全Role・全テンプレートの構文だけを解析し、エラーが無ければ`playbook: site.yml`とだけ表示して終了する。実際にサーバーへは一切接続しない。

**なぜ**: インデントミスなどのYAML文法エラーは、この段階で機械的に検出できる。サーバーに接続してから文法エラーで落ちるより、先に机上で弾いておいた方が安全かつ高速。

## Step 7. dry run(--check --diff)で影響範囲を事前確認する

```bash
ansible-playbook site.yml --check --diff
```

```text
PLAY [Webサーバーの初期構築を自動化する(共通設定 / ユーザー / ファイアウォール / Nginx)] ***

TASK [Gathering Facts] ************************************************
ok: [web01]
ok: [web02]

TASK [common : パッケージキャッシュを更新する(Debian/Ubuntu系のみ)] ***
changed: [web01]
skipping: [web02]

TASK [common : 共通パッケージをインストールする] ****************
changed: [web01]
changed: [web02]

TASK [common : タイムゾーンをAsia/Tokyoに設定する] **************
changed: [web01]
changed: [web02]

TASK [users : 作業用一般ユーザーを作成する] **********************
changed: [web01]
changed: [web02]

TASK [nginx : Nginxのバーチャルホスト設定を配置する] *************
--- before
+++ after
@@ -0,0 +1,15 @@
+# Ansible管理ファイル: このファイルはAnsibleにより自動生成されました。
+server {
+    listen 80 default_server;
+    ...
changed: [web01]
changed: [web02]

...(以下、全Roleのタスクが続く)...

PLAY RECAP **************************************************************
web01                      : ok=20   changed=17   unreachable=0    failed=0    skipped=3    rescued=0    ignored=0
web02                      : ok=16   changed=14   unreachable=0    failed=0    skipped=6    rescued=0    ignored=0
```

**何をしているか**: `--check`は実際には何も変更せず、「実行したら何が起きるか」だけを判定する(dry run)。`--diff`を付けると、`template`/`copy`のようなファイル生成系タスクについて、変更前後の差分(diff)まで表示してくれる。

**なぜ**: 本番環境に近いサーバーに対して、いきなり本適用するのはリスクが高い。事前に「想定通りの変更だけが行われるか」を目視確認する習慣をつける。

💡ポイント: `--check`モードには限界もある。例えば「このパッケージをインストールしたら、後続のタスクの前提条件が変わる」ようなケースを完全には予測しきれないことがある(詳しくは[05-troubleshooting.md](./05-troubleshooting.md) Q8、[04-test-plan.md](./04-test-plan.md)のTC-03)。あくまで「参考情報」として使い、過信しすぎないこと。

## Step 8.【安全な適用・前半】ユーザー作成のみを先に適用する

いきなり全部を適用せず、まずは「ユーザー作成とSSH鍵の配置」だけを先に行い、新しいユーザーでログインできることを確認してから、パスワード認証の無効化(SSHロックダウン)に進む。この2段階に分けることで、「鍵の配置ミスに気づかないままパスワード認証を無効化し、サーバーに一切入れなくなる」という事故を防ぐ。

```bash
ansible-playbook site.yml --tags "common,users" --skip-tags "ssh_lockdown"
```

```text
PLAY [Webサーバーの初期構築を自動化する(共通設定 / ユーザー / ファイアウォール / Nginx)] ***

TASK [Gathering Facts] ************************************************
ok: [web01]
ok: [web02]

TASK [common : パッケージキャッシュを更新する(Debian/Ubuntu系のみ)] ***
changed: [web01]
skipping: [web02]

TASK [common : 共通パッケージをインストールする] ****************
changed: [web01]
changed: [web02]

TASK [common : タイムゾーンをAsia/Tokyoに設定する] **************
changed: [web01]
changed: [web02]

TASK [users : 管理者グループ名をOSファミリーに応じて決定する] ****
ok: [web01]
ok: [web02]

TASK [users : 作業用一般ユーザーを作成する] **********************
changed: [web01]
changed: [web02]

TASK [users : SSH公開鍵を配置する] ******************************
changed: [web01]
changed: [web02]

TASK [users : パスワード無しでsudoできるようにする] **************
changed: [web01]
changed: [web02]

PLAY RECAP **************************************************************
web01                      : ok=8    changed=6    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
web02                      : ok=7    changed=5    unreachable=0    failed=0    skipped=1    rescued=0    ignored=0
```

**何をしているか**: `--tags "common,users"`で「common Role」と「users Role」のタスクだけに絞り込み、さらに`--skip-tags "ssh_lockdown"`で、その中でも`ssh_lockdown`タグが付いた2つのタスク(パスワード認証無効化・rootログイン無効化)だけを除外している。firewall Role・nginx Roleは今回のタグに含まれないため、一切実行されていない。

💡ポイント: `--tags`でタグ絞り込みされて実行対象から外れたタスクは、`skipping:`という行すら表示されない(そもそも「対象外」として最初から選ばれていない)。一方、`when:`条件で対象外になったタスク(例: `web02`での`apt-update`)は`skipping: [web02]`と明示的に表示される。この2つは似ているようで、表示のされ方が異なる点を覚えておくとログが読みやすくなる。

## Step 9. 新しいユーザーでのSSH鍵ログインを確認する

**★ここが最も重要な確認ステップ★**。別のターミナルを開き、作成した`webadmin`ユーザーで鍵ログインできることを確認する。

```bash
ssh -i ~/.ssh/id_ed25519_ansible webadmin@203.0.113.10
```

```text
Welcome to Ubuntu 22.04.4 LTS (GNU/Linux 5.15.0-91-generic x86_64)
...
webadmin@web01:~$
```

ログインできたら、sudo(パスワード無しで管理者権限に昇格できること)も確認する。

```bash
webadmin@web01:~$ sudo whoami
```

```text
root
```

ログインできることを確認できたら、いったんログアウトしておく。

```bash
webadmin@web01:~$ exit
```

💡ポイント: この時点では、まだ`PasswordAuthentication`も`PermitRootLogin`も無効化されていない(rootでのSSHログインも引き続き可能)。つまり、もしこのStepでログインに失敗しても、rootアクセスという「逃げ道」がまだ残っている。落ち着いてStep 3(鍵の生成)・Step 4(Inventory設定)の内容を見直せばよい。ここで失敗したまま次のStepへ進まないこと。

## Step 10.【安全な適用・後半】残りすべてを適用する

新しいユーザーでのログインが確認できたら、タグの指定なしで`site.yml`全体を適用する。ここでSSHロックダウン(パスワード認証・rootログインの無効化)・ファイアウォール設定・Nginx構築が行われる。

```bash
ansible-playbook site.yml
```

```text
PLAY [Webサーバーの初期構築を自動化する(共通設定 / ユーザー / ファイアウォール / Nginx)] ***

TASK [Gathering Facts] ************************************************
ok: [web01]
ok: [web02]

...(common/usersの前半タスクはStep 8で適用済みのため、ここでは ok のまま changed は発生しない)...

TASK [users : sshd_configでパスワード認証を無効化する] ************
changed: [web01]
changed: [web02]

TASK [users : sshd_configでrootの直接ログインを無効化する] ********
changed: [web01]
changed: [web02]

RUNNING HANDLER [users : Restart sshd] *********************************
changed: [web01]
changed: [web02]

TASK [firewall : ufwパッケージをインストールする] ****************
changed: [web01]
skipping: [web02]

...(firewall Role、続けてnginx Roleのタスクが続く)...

RUNNING HANDLER [nginx : Validate nginx config] ************************
ok: [web01]
ok: [web02]

RUNNING HANDLER [nginx : Reload nginx] *********************************
changed: [web01]
changed: [web02]

PLAY RECAP **************************************************************
web01                      : ok=23   changed=14   unreachable=0    failed=0    skipped=3    rescued=0    ignored=0
web02                      : ok=19   changed=11   unreachable=0    failed=0    skipped=6    rescued=0    ignored=0
```

**何をしているか**: Step 8で未適用だった`ssh_lockdown`タグのタスク、firewall Role、nginx Roleがすべて実行される。common/usersの基本部分は既に適用済みのため`changed`にはならず、差分だけが反映される。

**確認**: このタイミングで、Step 9と同じコマンドで`root`でのSSHログインを試すと、以下のように拒否されるはずである(意図した通りの状態)。

```bash
ssh -i ~/.ssh/id_ed25519_bootstrap root@203.0.113.10
```

```text
root@203.0.113.10: Permission denied (publickey).
```

## Step 11. 動作確認(Nginxの静的ページ公開)

```bash
curl -s http://203.0.113.10/
```

```html
<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="UTF-8">
  <title>Sample Web Service (Provisioned by Ansible)</title>
</head>
<body>
  <h1>Sample Web Service (Provisioned by Ansible)</h1>
  <p>このページはAnsible Playbook(site.yml)によって自動構築されました。</p>
  <ul>
    <li>ホスト名: web01</li>
    <li>OS: Ubuntu 22.04</li>
    <li>構築日時: 2026-08-31T10:40:12Z</li>
  </ul>
</body>
</html>
```

`web02`側も確認する。

```bash
curl -s http://203.0.113.11/
```

```text
    <li>ホスト名: web02</li>
    <li>OS: AlmaLinux 9.3</li>
```

**何をしているか**: HTTP経由で静的ページを取得し、`index.html.j2`で埋め込んだ`ansible_facts`(ホスト名・OS情報)が、実際のサーバーごとに異なる値で反映されていることを確認している。

## Step 12. べき等性の確認(2回目の実行)

同じコマンドをもう一度実行し、`changed`が0件になることを確認する。これが、この案件で最も重要な確認ポイントの1つ。

```bash
ansible-playbook site.yml
```

```text
PLAY RECAP **************************************************************
web01                      : ok=20   changed=0    unreachable=0    failed=0    skipped=3    rescued=0    ignored=0
web02                      : ok=16   changed=0    unreachable=0    failed=0    skipped=6    rescued=0    ignored=0
```

**確認できたこと**: `changed=0`になっている。これは「すべてのタスクが、既に望ましい状態に到達していることを確認し、何も変更しなかった」ことを意味する(=べき等性が保たれている)。

> 💡 なぜ`ok`の数がStep 10より少なくなっているのか
> Step 10では、設定変更をトリガーに`Restart sshd`・`Validate nginx config`・`Reload nginx`という3つのHandlerが実行された(`ok`または`changed`としてカウントされた)。今回は変更が一切発生しなかったため、これらのHandlerは**そもそも呼び出されず**、実行結果としてカウントされていない。Handlerは「notifyされたときだけ動く」という性質を、この数字の変化からも確認できる。

## Step 13. verify.shで要件充足を自動チェックする

`src/verify.sh`を使い、要件([01-requirements.md](./01-requirements.md))を満たしているかをまとめて確認する。`ansible.builtin.script`モジュールを使うと、コントロールノード上のスクリプトをその場で対象サーバーに転送・実行できる。

```bash
ansible webservers -m ansible.builtin.script -a "verify.sh" --become
```

```text
web01 | CHANGED | rc=0 >>
=== 1. Nginxサービスが稼働しているか ===
[PASS] nginxサービスがactiveである
=== 2. ポート80で静的ページが取得できるか ===
[PASS] http://localhost/ が200を返す
=== 3. タイムゾーンがAsia/Tokyoに設定されているか ===
[PASS] タイムゾーンがAsia/Tokyoである
=== 4. SSHのパスワード認証が無効化されているか ===
[PASS] sshd_configでPasswordAuthentication noになっている
=== 5. rootの直接SSHログインが無効化されているか ===
[PASS] sshd_configでPermitRootLogin noになっている
=== 6. ファイアウォールが有効で、許可設定が入っているか ===
  ufw status: Status: active
[PASS] ufwが有効化されている(Status: active)

=== 結果サマリ ===
PASS: 6  FAIL: 0
すべてのチェックに合格しました。

web02 | CHANGED | rc=0 >>
...(同様の結果。ufwの代わりにfirewalldのチェックが実行される)...
```

💡ポイント: 実行結果が`CHANGED`と表示されているが、これは`verify.sh`が実際にサーバーの状態を変えたという意味ではない。`script`モジュールは「スクリプトを実行した」という事実だけを見て、常に`changed`として報告する仕様になっている(スクリプトの中身までは解釈できないため)。本当に「べき等かどうか」を確認したい場合は、Step 12のようにPlaybook本体の`changed`カウントを見る必要がある。

## Step 14.(応用)設定ドリフトからの復旧を体験する

IaCの価値を体感するため、「誰かが手動でサーバーの設定を書き換えてしまった」状況を擬似的に再現し、Playbookの再実行で元に戻ることを確認する。

```bash
# 本来はSSHで直接ログインして手作業を行うイメージだが、
# ここでは検証のため ansible の shell モジュールで擬似的に再現する
ansible web01 -m ansible.builtin.shell \
  -a "echo '<h1>誰かが手動で書き換えました</h1>' > /var/www/html/index.html" \
  --become
```

書き換わったことを確認する。

```bash
curl -s http://203.0.113.10/
```

```html
<h1>誰かが手動で書き換えました</h1>
```

ここでPlaybookを再実行する。

```bash
ansible-playbook site.yml --diff
```

```text
TASK [nginx : 公開する静的ページ(index.html)を配置する] ***
--- before
+++ after
@@ -1 +1 @@
-<h1>誰かが手動で書き換えました</h1>
+<!DOCTYPE html>
+<html lang="ja">
...
changed: [web01]

PLAY RECAP **************************************************************
web01                      : ok=21   changed=1    unreachable=0    failed=0    skipped=3    rescued=0    ignored=0
```

```bash
curl -s http://203.0.113.10/
```

```html
<!DOCTYPE html>
<html lang="ja">
...
```

**確認できたこと**: 手作業で加えられた変更が、Playbookの再実行によって「あるべき状態」(コードで定義した状態)へ自動的に戻された。これは手作業運用では得られない、IaCならではのメリットになる。「サーバーの正しい状態はコードに書いてある」という前提があるからこそ、誰が何を書き換えても、コードを実行し直せば正しい状態に戻せる。

## Step 15. 最終確認チェックリスト

| 確認項目 | コマンド | 期待結果 |
|---|---|---|
| Playbookの構文が正しい | `ansible-playbook site.yml --syntax-check` | `playbook: site.yml`とだけ表示される |
| 全ホストに疎通できる | `ansible all -m ansible.builtin.ping` | 全ホストで`"ping": "pong"` |
| Nginxが稼働している | `curl -s -o /dev/null -w '%{http_code}\n' http://<IP>/` | `200` |
| タイムゾーンが正しい | `ansible webservers -m ansible.builtin.command -a "timedatectl show --property=Timezone --value" --become` | `Asia/Tokyo` |
| パスワード認証が無効 | `ssh -o PreferredAuthentications=password webadmin@<IP>` | パスワードプロンプトが出ず、接続が拒否される |
| rootの直接ログインが無効 | `ssh -i <bootstrap鍵> root@<IP>` | `Permission denied (publickey).` |
| ファイアウォールで許可されていないポートは閉じている | `curl --connect-timeout 3 http://<IP>:8080/` | タイムアウトまたは接続拒否 |
| 2回目の実行でchanged=0 | `ansible-playbook site.yml`(2回連続実行) | 2回目の`PLAY RECAP`で`changed=0` |

すべて満たしていれば構築完了。詳細なテストケースは[04-test-plan.md](./04-test-plan.md)を参照。
