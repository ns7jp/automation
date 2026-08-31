# 04. テスト仕様書

[03-build-guide.md](./03-build-guide.md)の手順で構築した環境に対して実施するテストケース一覧。正常系(想定通りに動くこと)と異常系(想定外の状況でも安全に倒れること)の両方を確認する。

## 1. テスト方針

- 実データを壊さないよう、異常系テストでは可能な限り**設定値を一時的に変更**して擬似的に状況を再現する
- 世代管理のテストは、実際に7日間待つのではなく`touch -d`で更新日時を偽装したダミーファイルを使う
- テスト後は必ず設定値やファイルパーミッションを元の状態に戻す(TC-08、TC-09〜TC-14が該当。戻し忘れがないかも確認項目に含める)

## 2. テストケース一覧

| テストID | 分類 | 前提条件 | 操作手順 | 期待結果 |
|---|---|---|---|---|
| TC-01 | 正常系 | `BACKUP_SRC_DIR`が存在し、`BACKUP_DEST_DIR`が空の状態 | `sudo /opt/backup-automation/backup.sh` を実行する | `BACKUP_DEST_DIR`配下に`html-backup-YYYYMMDD.tar.gz`が作成される。終了コードが`0`。ログに`ERROR`が含まれない |
| TC-02 | 正常系 | TC-01実施後 | 生成されたファイル名の日付部分と、実行日(`date +%Y%m%d`の結果)を比較する | ファイル名の日付が実行日と一致する |
| TC-03 | 正常系 | `tar tzvf`でバックアップの中身を確認できる状態 | `tar tzvf <backup.tar.gz>` を実行する | 対象ディレクトリ配下のファイル一覧(例: `html/index.html`)が表示され、欠損がない |
| TC-04 | 正常系 | `BACKUP_DEST_DIR`に8日前・9日前のタイムスタンプを持つダミーファイルと、5日前のダミーファイルが存在する | `sudo /opt/backup-automation/backup.sh` を実行する | 8日前・9日前のファイルは削除され、5日前のファイルと本日分のファイルは残る。削除内容がログに`INFO`で記録される |
| TC-05 | 正常系 | RETENTION_DAYS=7のまま、削除対象ファイルが存在しない状態 | `sudo /opt/backup-automation/backup.sh` を実行する | ログに「削除対象の古いバックアップはありませんでした」と記録され、エラーにならない |
| TC-06 | 正常系(べき等性) | TC-01実施済みで、当日中に再実行する | 同日中に `sudo /opt/backup-automation/backup.sh` をもう一度実行する | 同名ファイルが上書きされるだけで、エラーや重複ファイルが発生しない。終了コードが`0` |
| TC-07 | 正常系 | `crontab -l`に`0 3 * * *`の行が登録済み | AM3:00を跨ぐまで待つ、または`sudo run-parts`相当の検証としてcrontabの記述内容を目視確認する | `cron.log`と`backup.log`の両方に該当時刻の実行記録が残る |
| TC-08 | 正常系(発展要件) | `DISK_USAGE_THRESHOLD`を`1`など極端に低い値に一時変更 | `sudo /opt/backup-automation/backup.sh` を実行する | ログに`WARN`が記録され、Slackに`:warning: [容量警告]`メッセージが届く。バックアップ自体は正常に完了する(処理は止まらない) |
| TC-09 | 異常系 | `BACKUP_SRC_DIR`を存在しないパスに一時変更 | `sudo /opt/backup-automation/backup.sh` を実行する | ログに`ERROR`(対象ディレクトリが存在しない旨)が記録され、Slackに`:x: [バックアップ失敗]`が届く。終了コードが`1` |
| TC-10 | 異常系 | `BACKUP_DEST_DIR`のパーミッションを書き込み不可(`chmod 500`等)に一時変更 | `sudo -u <一般ユーザー> /opt/backup-automation/backup.sh` を実行する | `tar`がファイル作成に失敗し、ログに`ERROR`(tar終了コード)が記録される。Slackに失敗通知が届く。終了コードが`1` |
| TC-11 | 異常系 | `SLACK_WEBHOOK_URL`を無効な値(存在しないURL)に一時変更し、TC-09相当の失敗を発生させる | `sudo /opt/backup-automation/backup.sh` を実行する | `curl`自体は通知に失敗するが、その失敗によってスクリプトが異常終了することはなく、ログへの`ERROR`記録は正しく残る(通知失敗がログ記録を妨げない) |
| TC-12 | 異常系 | `/opt/backup-automation/backup.conf`を一時的にリネームして存在しない状態にする | `sudo /opt/backup-automation/backup.sh` を実行する | 「設定ファイルが見つかりません」というメッセージが標準エラー出力に表示され、即座に終了コード`1`で終了する(ログファイルへの書き込みは行われない) |
| TC-13 | 異常系 | `backup.sh`の実行権限(`x`)を外した状態(`chmod -x`) | `/opt/backup-automation/backup.sh` を直接実行する | `Permission denied`となり実行できない。`bash /opt/backup-automation/backup.sh`のように明示的にインタプリタを指定すれば実行できることを確認する |
| TC-14 | 異常系 | `backup.conf`の権限が`600`ではなく`644`など緩い状態 | `ls -l /opt/backup-automation/backup.conf` で権限を確認する | 権限が要件(NFR-03、所有者以外読み取り不可)を満たしていないことを検出できる。運用チェック項目として、定期的にこの権限を確認する運用ルールを設ける |

## 3. テスト結果の記録方法

各テストケースについて、実施日・実施者・結果(OK/NG)・ログの抜粋を記録する。以下は記録テンプレートの例。

```text
テストID: TC-04
実施日: 2026-08-31
実施者: (氏名)
結果: OK
ログ抜粋:
  2026-08-31 10:22:10 [INFO] 古いバックアップを削除します: /var/backups/html-backup/html-backup-20260822.tar.gz
  2026-08-31 10:22:10 [INFO] 古いバックアップを削除します: /var/backups/html-backup/html-backup-20260823.tar.gz
備考: 5日前・本日分のファイルが残存していることを ls -la で確認済み
```

## 4. 完了基準

- TC-01〜TC-14のすべてが期待結果通りであること
- テストのために一時的に変更した設定値・ファイルパーミッション(TC-08の`DISK_USAGE_THRESHOLD`、TC-09の`BACKUP_SRC_DIR`、TC-10の`BACKUP_DEST_DIR`権限、TC-11の`SLACK_WEBHOOK_URL`、TC-12の`backup.conf`のリネーム、TC-13の`backup.sh`権限、TC-14の`backup.conf`権限)が、テスト後にすべて元の状態(`backup.sh`:755、`backup.conf`:600 など)へ戻っていること
- Slack通知が実際にチャンネルへ届くことを、目視で最低1回確認していること
