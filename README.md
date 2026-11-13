# automation — Linux 運用自動化の学習教材

<a id="automation"></a>

ユーザー管理・バックアップ・監視などを題材に、**要件 → 設計 → 実装 → 確認**を練習する教材です。架空の構築6案件、Bash演習21問、改善6案件を収録しています。

採用向けの本人操作の記録は、主作品 **[サーバー構築・監視ラボ `server`](https://github.com/ns7jp/server)** にまとめています。このリポジトリの教材・面接文例と、本人が実施した経験は区別してご覧ください。

## 最初に見る例

**[サーバー死活監視・障害検知](projects/04-server-health-check/README.md)**：ping / HTTP で状態を確認し、連続失敗の回数を保持して通知する設計です。[設計書](projects/04-server-health-check/02-design.md) → [コード](projects/04-server-health-check/src/health_check.sh) → [テスト仕様](projects/04-server-health-check/04-test-plan.md)の順に確認できます。

改善の題材には[月次報告書の自動生成](improvements/01-ops-report-automation/README.md)があります。「3時間→5分」などの改善値は **架空シナリオに基づく指標で、本人の実務実績ではありません**。前提値・試算・検証環境での実測は[効果測定レポート](improvements/01-ops-report-automation/05-effect-measurement.md)で区別しています。

## 確認できる範囲

| 対象 | 確認先・読み方 |
| --- | --- |
| 設計・実装・手順 | 各案件にコード、設計書、テスト仕様を掲載。出力例や期待結果は実行証拠と区別します |
| 演習パックの自動検査 | [CI](.github/workflows/exercises-check.yml)は解答例の採点、シェル構文・静的解析、演習一覧の整合性を検査します |
| 実機動作・本人の技能 | 演習のCIだけでは、構築6案件すべての実機動作や本人の独力再現・実務経験を確認できません |

## 教材を探す・試す

| 目的 | 開くページ |
| --- | --- |
| 構築6案件・演習21問・改善6案件から選ぶ | [教材一覧と学習ガイド](docs/materials-index.md) |
| Bashの小さな演習から始める | [演習パック](exercises/README.md)・[環境準備と最初の1問](exercises/docs/02-getting-started.md) |
| 運用の分析・改善を練習する | [改善案件一覧](improvements/README.md) |
| 計画・用語・環境を確認する | [学習ロードマップ](docs/02-learning-roadmap.md)・[用語集](docs/03-glossary.md)・[環境構築](docs/04-environment-setup.md) |

<details>
<summary>以前のREADMEの節から探す</summary>

<a id="このポートフォリオのコンセプト"></a><a id="収録案件一覧"></a><a id="手を動かして覚える-自動化スクリプト演習パック"></a><a id="現状を分析して直す-自動化改善ツール構築-案件パック"></a><a id="学習の進め方概要"></a><a id="リポジトリ構成"></a><a id="このポートフォリオの使い方"></a><a id="関連ドキュメント一覧"></a>

コンセプト、全案件の一覧、学習手順、ディレクトリ構成は[教材一覧と学習ガイド](docs/materials-index.md)へ移しました。

</details>

## ライセンス

[MIT License](LICENSE)
