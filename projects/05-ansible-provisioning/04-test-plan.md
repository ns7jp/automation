# 04. テスト仕様書

[03-build-guide.md](./03-build-guide.md)の手順で構築した環境に対して実施するテストケース一覧。正常系(想定通りに動くこと)と異常系(想定外の状況でも安全に倒れる、あるいは正しく検知できること)の両方を確認する。

## 1. テスト方針

- 可能な限り**壊れても復旧できる検証環境**(VMのスナップショット等)で実施し、異常系テストで本番相当のサーバーを壊さないようにする
- べき等性の確認は、実際に日を跨いで待つのではなく「同じコマンドを連続で2回実行する」ことで確認する
- 異常系テストで一時的に書き換えた設定(YAML・Inventory等)は、テスト後に必ず元へ戻す
- 可能なテストは`--check`(dry run)で先に確認してから、実際の適用(本実行)で再確認するという2段階で行う

## 2. テストケース一覧

| テストID | 分類 | 前提条件 | 操作手順 | 期待結果 |
|---|---|---|---|---|
| TC-01 | 正常系 | `site.yml`および全Role/テンプレートが用意されている状態 | `ansible-playbook site.yml --syntax-check` を実行する | `playbook: site.yml` とだけ表示され、終了コードが`0`。サーバーへは接続されない |
| TC-02 | 正常系 | Inventoryに正しいIP・鍵情報が設定済み | `ansible all -m ansible.builtin.ping` を実行する | 全ホストで`"ping": "pong"`、`"changed": false`が返る |
| TC-03 | 正常系 | 対象サーバーがまっさらな初期状態 | `ansible-playbook site.yml --check --diff` を実行する | 多数のタスクが`changed`と判定される(dry runのため実際には未適用)。実行後に`curl http://<IP>/`を試みると接続できない(まだ何も構築されていないことの確認) |
| TC-04 | 正常系 | TC-03実施済み | `ansible-playbook site.yml --tags "common,users" --skip-tags "ssh_lockdown"` を実行する | `PLAY RECAP`で`failed=0`。対象サーバーに`webadmin`ユーザーが作成され、`~webadmin/.ssh/authorized_keys`に公開鍵が登録される |
| TC-05 | 正常系 | TC-04実施済み | `ssh -i <ansible用秘密鍵> webadmin@<IP>` でログインを試みる | パスワード入力なしでログインに成功する。続けて`sudo whoami`を実行すると`root`が返る |
| TC-06 | 正常系 | TC-05でログイン成功を確認済み | `ansible-playbook site.yml` を実行する(タグ指定なし) | `PLAY RECAP`で`failed=0`。sshd・ufw(またはfirewalld)・nginxがすべて設定される |
| TC-07 | 正常系 | TC-06実施済み | `curl -s -o /dev/null -w '%{http_code}\n' http://<IP>/` を実行する | `200`が返る。`curl -s http://<IP>/`の本文に、対象ホストのホスト名・OS情報が含まれる |
| TC-08 | 正常系(べき等性) | TC-06実施済みの状態から間を置かず | `ansible-playbook site.yml` をもう一度実行する | `PLAY RECAP`で全ホスト`changed=0`、`failed=0`になる |
| TC-09 | 正常系 | TC-06実施済み(ファイアウォール適用後) | 許可していないポート(例: 8080)に対して `curl --connect-timeout 3 http://<IP>:8080/` を実行する | 接続がタイムアウトまたは拒否され、200番台のレスポンスは返らない |
| TC-10 | 正常系 | TC-06実施済み | `ssh -i <bootstrap鍵> root@<IP>` でrootへの直接ログインを試みる | `Permission denied (publickey).`となり、ログインできない |
| TC-11 | 正常系 | TC-06実施済み | 対象サーバー上で `sudo sshd -T \| grep -i passwordauthentication` を実行する(またはStep 13の`verify.sh`を利用) | `passwordauthentication no`が表示される |
| TC-12 | 正常系 | TC-06実施済み | 対象サーバー上で `timedatectl show --property=Timezone --value` を実行する | `Asia/Tokyo`が返る |
| TC-13 | 正常系(応用・config drift) | TC-06実施済み | `index.html`を手動(または擬似的にad-hocコマンドで)書き換えた後、`ansible-playbook site.yml --diff` を再実行する | `nginx : 公開する静的ページ(index.html)を配置する`タスクが`changed`になり、`--diff`にAnsible管理下の内容へ戻す差分が表示される。再度`curl`すると元の内容に復元されている |
| TC-14 | 異常系 | `roles/common/tasks/main.yml`のインデントを意図的に1文字ズラして壊す | `ansible-playbook site.yml --syntax-check` を実行する | `ERROR! ... could not find expected ':'` 等のYAML構文エラーが表示され、終了コードが`0`以外になる。**この時点でどのサーバーにも一切接続されていないこと**を確認する(構文チェックは接続前に行われるため) |
| TC-15 | 異常系 | `group_vars/all.yml`の`deploy_user_pubkey_file`を存在しないファイル名に変更 | `ansible-playbook site.yml --tags users` を実行する | `users : SSH公開鍵を配置する`タスクで`fatal: [web01]: FAILED! => ...could not locate file...`のようなエラーになり、そのホストの以降のタスクは実行されない(`failed=1`) |
| TC-16 | 異常系 | `~/.ansible/collections/`配下から`ansible.posix`を一時的に退避(未インストール状態を再現) | `ansible-playbook site.yml --tags users` を実行する | `ERROR! couldn't resolve module/action 'ansible.posix.authorized_key'`のようなエラーになり、Playbookが開始前後で停止する |
| TC-17 | 異常系 | `inventory/hosts.ini`の`ansible_host`を、到達不可能なアドレス(例: `203.0.113.250`)に一時変更 | `ansible all -m ansible.builtin.ping` を実行する | `UNREACHABLE!`となり、`"unreachable": true`が返る。他の正しいホストへは影響しない |
| TC-18 | 異常系 | `roles/users/tasks/main.yml`の`sudoers`生成タスクの`content:`を、意図的に文法の壊れた内容(例: `ALL=(ALL) NOPASSWD ALL`のように区切り記号を欠落させる)に変更 | `ansible-playbook site.yml --tags users` を実行する | `validate: "visudo -cf %s"`が文法エラーを検知し、`/etc/sudoers.d/webadmin`へは反映されずタスクが失敗する(`failed=1`)。既存のsudoers設定は壊れない |
| TC-19 | 異常系 | `roles/nginx/templates/nginx.conf.j2`の`server {`を`server {{`のように意図的に壊す | `ansible-playbook site.yml --tags nginx` を実行する | `Validate nginx config`ハンドラの`nginx -t`が文法エラーを検知して失敗する。`Reload nginx`ハンドラは実行されず、稼働中のNginxの設定はそのまま(壊れた設定には切り替わらない) |

## 3. テスト結果の記録方法

各テストケースについて、実施日・実施者・結果(OK/NG)・実行結果の抜粋を記録する。以下は記録テンプレートの例。

```text
テストID: TC-08
実施日: 2026-08-31
実施者: (氏名)
結果: OK
実行結果抜粋:
  web01                      : ok=20   changed=0    unreachable=0    failed=0    skipped=3    rescued=0    ignored=0
  web02                      : ok=16   changed=0    unreachable=0    failed=0    skipped=6    rescued=0    ignored=0
備考: 2回連続実行し、2回目のchangedがすべて0であることを確認した
```

## 4. 完了基準

- TC-01〜TC-19のすべてが期待結果通りであること
- 異常系テスト(TC-14〜TC-19)で意図的に壊した設定・ファイルが、テスト後にすべて元の状態へ戻っていること
- TC-08(べき等性の確認)は、`web01`(Debian系)・`web02`(RedHat系)の両方で実施し、いずれも`changed=0`であることを確認していること
- TC-09(ファイアウォール)・TC-10(root無効化)・TC-11(パスワード認証無効化)は、Nginxの動作確認だけで終わらせず、**セキュリティ要件として個別に**確認していること
