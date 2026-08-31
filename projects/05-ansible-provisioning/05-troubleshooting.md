# 05. トラブルシューティング集

構築・運用中によく遭遇するトラブルをQ&A形式でまとめる。

---

## Q1. `ansible-playbook`実行時に`mapping values are not allowed in this context`と表示される

**現象**

```bash
ansible-playbook site.yml --syntax-check
```

```text
ERROR! Syntax Error while loading YAML.
  mapping values are not allowed in this context

The error appears to be in '/home/user/.../roles/common/tasks/main.yml': line 8, column 24, but may
be elsewhere in the file depending on the exact syntax problem.
```

**原因**

YAMLのインデント(字下げ)が1文字でもズレていたり、コロン`:`の後に必要な半角スペースが無かったりすると発生する典型的なエラー。例えば以下のように、キーと値の間のスペースが抜けている場合に起きやすい。

```yaml
# NG例(コロンの後にスペースが無い)
name:パッケージをインストールする

# OK例
name: パッケージをインストールする
```

**対処法**

1. エラーメッセージに表示されたファイル名・行番号(例: `main.yml: line 8`)を確認する
2. その行と、前後数行のインデント幅(半角スペースの数)が揃っているか目視確認する
3. エディタの設定で「タブをスペースに自動変換する」機能を有効にしておくと、タブ文字混入によるエラーを防げる

💡ポイント: YAMLの構文エラーは、実際にサーバーへ接続する**前**に検出できる。`ansible-playbook site.yml --syntax-check`を実行の習慣にしておけば、サーバーに影響が及ぶ前にミスへ気づける([03-build-guide.md](./03-build-guide.md) Step 6を参照)。

---

## Q2. `UNREACHABLE! => Permission denied (publickey)`と表示される

**現象**

```bash
ansible all -m ansible.builtin.ping
```

```text
web01 | UNREACHABLE! => {
    "changed": false,
    "msg": "Failed to connect to the host via ssh: web01: Permission denied (publickey).",
    "unreachable": true
}
```

**原因(よくあるもの)**

| 原因 | 確認方法 |
|---|---|
| `inventory/hosts.ini`の`ansible_ssh_private_key_file`が間違っている、または鍵ファイルが存在しない | `ls -l ~/.ssh/id_ed25519_bootstrap` |
| `ansible_user`が実際のサーバーの初期ユーザーと合っていない(例: `root`と書いているが実際は`ubuntu`) | 手動で`ssh -i <鍵> <ユーザー>@<IP>`を試す |
| SSHロックダウン適用後、既に`root`でのパスワード/鍵ログインが無効化されている状態で`root`のまま接続しようとしている | [03-build-guide.md](./03-build-guide.md) Step 10以降は、`ansible_user`を`webadmin`に切り替える必要がある |

**対処法**

まずAnsibleを介さず、素のSSHコマンドで同じ接続を試し、エラーメッセージの詳細を確認する。

```bash
ssh -vi ~/.ssh/id_ed25519_bootstrap root@203.0.113.10
```

`-v`(verbose)オプションを付けると、どの鍵を試してどこで拒否されたかが詳しく表示されるため、Ansible経由よりも原因を特定しやすい。

---

## Q3. 初回接続時に`Host key verification failed`と表示される

**現象**

```text
fatal: [web01]: UNREACHABLE! => {"changed": false, "msg": "Host key verification failed."}
```

**原因**

SSHには「接続先のホストが本物かどうか」を検証する仕組みがあり、初めて接続するサーバーの場合、`~/.ssh/known_hosts`にそのサーバーの「ホスト鍵の指紋」が登録されていないと、この確認で止まる。

**対処法**

検証用途であれば、`src/ansible.cfg`の`host_key_checking = False`設定によって、通常はこの確認自体がスキップされる仕組みになっている。それでもこのエラーが出る場合は、`ansible.cfg`が正しく読み込まれているか(`src/`ディレクトリで実行しているか)を確認する。

```bash
ansible-config dump --only-changed | grep HOST_KEY_CHECKING
```

```text
DEFAULT_HOST_KEY_CHECKING(/home/user/.../src/ansible.cfg) = False
```

上記のように`ansible.cfg`が反映されていれば設定は有効。本番環境では、`ssh-keyscan`で事前にホスト鍵を`known_hosts`へ登録しておき、`host_key_checking`は`True`(デフォルト)のままにする方が、なりすましサーバーへの誤接続を防げるためセキュリティ上望ましい。

```bash
ssh-keyscan -H 203.0.113.10 >> ~/.ssh/known_hosts
```

---

## Q4. パスワード認証を無効化したら、サーバーに一切ログインできなくなった

**現象**

`ansible-playbook site.yml`(タグ指定なしのフル実行)をいきなり実行してしまい、`webadmin`ユーザーの鍵が正しく登録されていない状態のまま`PasswordAuthentication no`・`PermitRootLogin no`が適用され、どのユーザーでもSSHログインできなくなった。

**原因**

[03-build-guide.md](./03-build-guide.md) Step 8〜10で案内している「ユーザー作成 → 鍵ログイン確認 → SSHロックダウン適用」という2段階の手順を踏まず、確認を挟まずに一度で全部適用してしまったことが原因。ユーザー作成時に指定した公開鍵ファイル(`files/webadmin_id_ed25519.pub`)の中身が誤っていた場合などに起きる。

**対処法**

- クラウドVMの場合: 多くのクラウドサービスには、SSHを経由せずサーバーのコンソール画面へ直接アクセスできる機能(シリアルコンソール、VNCコンソール等)が用意されている。それを使ってログインし、`/etc/ssh/sshd_config`の該当行を手動で修正して`sshd`を再起動する
- オンプレミス/VMの場合: ハイパーバイザーのコンソール機能や、レスキューモードでの起動などを使い、同様にファイルを修正する
- 復旧できたら、`files/webadmin_id_ed25519.pub`の中身を再確認し、Step 8からやり直す

**予防法(最重要)**

- 必ず`--tags "common,users" --skip-tags "ssh_lockdown"`で先にユーザー作成だけを適用し、**別ターミナルで新ユーザーの鍵ログインが成功することを確認してから**、ロックダウンを含むフル実行に進む(このドキュメントの手順は最初からこの順序になっている)
- 検証段階では、コンソールアクセスが確保できる環境(クラウドVMやVagrant等)で試すこと

---

## Q5. `ERROR! couldn't resolve module/action 'ansible.posix.authorized_key'`と表示される

**現象**

```text
ERROR! couldn't resolve module/action 'ansible.posix.authorized_key'. This often indicates a
misspelling, missing collection, or incorrect module path.
```

**原因**

`ansible.posix`や`community.general`は、Ansible本体(`ansible-core`)には含まれない別配布のCollection。`ansible-galaxy collection install -r requirements.yml`を実行していないコントロールノードでは、これらのモジュールが見つからない。

**対処法**

```bash
ansible-galaxy collection install -r requirements.yml
```

インストール済みのCollectionと、そのバージョンは以下で確認できる。

```bash
ansible-galaxy collection list | grep -E "ansible.posix|community.general"
```

```text
ansible.posix           1.5.4
community.general       8.3.0
```

💡ポイント: このプロジェクトを別のPC(新しいコントロールノード)にコピーして使う場合も、`requirements.yml`をコミットしておけば「必要なCollectionが何か」がコードとして残る。これもIaCの一部と言える。

---

## Q6. Nginxが起動せず`a duplicate default server for 0.0.0.0:80`というエラーが出る

**現象**

```bash
sudo nginx -t
```

```text
nginx: [emerg] a duplicate default server for 0.0.0.0:80 in /etc/nginx/sites-enabled/default:1
nginx: configuration file /etc/nginx/nginx.conf test failed
```

**原因**

Ubuntu標準のnginxパッケージには、あらかじめ`/etc/nginx/sites-enabled/default`という「ポート80のデフォルトサイト」設定が入っている。本Playbookが配置する`/etc/nginx/conf.d/portfolio-site.conf`も同じく`listen 80 default_server;`を宣言しているため、両方が有効なままだと「デフォルトサーバーの重複」としてNginxが起動を拒否する。

**対処法**

`roles/nginx/tasks/main.yml`には、この重複を避けるため`sites-enabled/default`を削除するタスクが最初から含まれている。もしこのエラーが出た場合は、そのタスクが正しく実行されたか確認する。

```bash
ls -l /etc/nginx/sites-enabled/
```

```text
（何も表示されなければ正常。defaultファイルが残っていたら手動で確認する)
```

なお、AlmaLinux系のnginxパッケージにはこの`sites-enabled`という仕組み自体が無いため、このエラーはUbuntu/Debian系でのみ発生しうる。

---

## Q7. firewalldの設定で`Failed to connect to bus: No such file or directory`と表示される

**現象**

```text
fatal: [web02]: FAILED! => {"changed": false, "msg": "Failed to connect to bus: No such file or directory"}
```

**原因**

`ansible.posix.firewalld`モジュールは、内部的にfirewalldのD-Busインターフェース(=Linux上でプロセス同士がやり取りするための標準的な通信の仕組み)へ接続して設定を行う。firewalldサービス自体が起動していない状態でこのモジュールを使うと、接続先が無いため失敗する。

**対処法**

`roles/firewall/tasks/RedHat.yml`では、firewalldモジュールを使う**前に**必ずサービスを起動・有効化するタスクを置いている。

```yaml
- name: firewalldサービスを起動・自動起動有効化する
  ansible.builtin.systemd:
    name: firewalld
    state: started
    enabled: true
```

このタスクが何らかの理由でスキップ・失敗していないか確認する。手動で確認する場合は、対象サーバー上で以下を実行する。

```bash
sudo systemctl status firewalld
```

---

## Q8. `--check`(dry run)の結果と、実際に適用したときの結果が異なる

**現象**

`ansible-playbook site.yml --check --diff`では「変更なし」と表示されたタスクが、`--check`を外して本実行すると`changed`になることがある。

**原因**

`--check`モードはあくまで「今の状態から推測して、変更が必要かどうかを判定する」仕組みであり、一部のモジュール(特に`command`/`shell`のように、Ansibleが結果を構造的に把握できないもの)は、dry runと実際の実行で結果が食い違うことがある。また、あるタスクの結果が後続タスクの判定材料になっている場合、dry runでは「まだ実行されていない前提」で判定するため、本実行時と状況が異なることもある。

**対処法**

- 本Playbookでは`command`/`shell`モジュールの使用を極力避け、`package`/`user`/`template`のような、べき等性を正しく判定できる専用モジュールを優先している。これにより`--check`との差異はある程度小さく抑えられている
- それでも差異が疑われる場合は、`--check`の結果を過信せず、影響の小さい範囲(1台だけ、あるいは特定のRoleだけ)から本適用して段階的に確認する(`--limit web01`や`--tags`の活用)

---

## Q9. sudoersやsshd_configの変更が反映されず`Failed to validate`のようなメッセージが出る

**現象**

```text
fatal: [web01]: FAILED! => {"changed": false, "msg": "failed to validate: rc:1 error:visudo: >>> /etc/sudoers.d/webadmin: syntax error near line 1 <<<"}
```

**原因**

`roles/users/tasks/main.yml`の`sudoers`生成タスクや`sshd_config`変更タスクには、あえて`validate`パラメータ(`visudo -cf %s`や`/usr/sbin/sshd -t -f %s`)を指定している。これは、ファイルの中身に文法的な誤りがあった場合、**本来のファイルへ反映する前**にそれを検知して処理を止めるための仕組み。エラーが出ているのは、この安全装置が正しく機能している状態と言える。

**対処法**

1. エラーメッセージに含まれる詳細(`syntax error near line 1`等)を確認する
2. 該当タスクの`content:`や`line:`に指定している値(通常は変数経由)が正しいか、`roles/users/defaults/main.yml`・`group_vars/all.yml`を見直す
3. 修正後、`--check --diff`で想定通りの内容になるか再確認してから本実行する

💡ポイント: `validate`パラメータを使わずにいきなり`/etc/sudoers`や`/etc/ssh/sshd_config`を上書きしてしまうと、壊れた設定のままでは`sudo`コマンドやSSH自体が使えなくなり、Q4のような詰みの状況につながりかねない。設定ミスが「反映される前」に弾かれる、という設計自体がこの案件の安全性を支えている。
