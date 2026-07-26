# SQL Server クエリ力強化プロジェクト

SQL Server の **T-SQL(Transact-SQL)言語仕様** をトピック別に学び、
**演習問題** で手を動かしながらクエリ力を鍛えるための学習プロジェクトです。

- 📖 **仕様解説** … 各機能の構文・意味・落とし穴を `docs/` にまとめています。
- ✏️ **演習問題** … 解説に対応した問題を `exercises/` に用意。解答は `exercises/solutions/`。
- 🗄 **共通サンプルDB** … すべての題材は `sample-db/` の `SalesLearning` を使います。

## 使い方

1. **環境を準備する** — SQL Server(またはコンテナ / Azure SQL)と、
   SSMS もしくは Azure Data Studio を用意します。詳細は
   [docs/00_environment.md](docs/00_environment.md)。
2. **サンプルDBを作る** — [sample-db/](sample-db/) の README に従い、
   `01_create_schema.sql` → `02_seed_data.sql` を実行します。
   性能編(15・18・21)に進むときは、追加で `03_bulk_data.sql`(100万行の
   性能検証用テーブル)も実行してください。
   上級編に進むときは、さらに `04_analytics_data.sql`(1000万行・30/31章用)と
   `05_workload.sql`(負荷生成・23/25/26章用)を使います。
3. **1トピックずつ進める** — `docs/NN_*.md` を読む → 対応する
   `exercises/NN_*.md` を自力で解く → `exercises/solutions/NN_*.sql` で答え合わせ。
4. **ロードマップで進捗を管理** — [ROADMAP.md](ROADMAP.md) のチェックリストを埋めていきます。

## 学習の流れ(1トピックあたり)

```
docs/NN を読む  ──▶  自分でクエリを書く  ──▶  exercises/NN を解く  ──▶  solutions で検証
     ▲                                                                      │
     └───────────────  間違えた/知らなかった点をメモに戻す  ◀───────────────┘
```

## ディレクトリ構成

```
SQLServerLearning/
├── README.md                 ← このファイル
├── ROADMAP.md                ← 学習ロードマップ / チェックリスト
├── sample-db/                ← 共通サンプルデータベース SalesLearning
│   ├── 01_create_schema.sql
│   ├── 02_seed_data.sql
│   ├── 03_bulk_data.sql      ← 性能検証用(100万行)     ※18章〜で使用
│   ├── 04_analytics_data.sql ← 分析検証用(1000万行)    ※30・31章で使用
│   ├── 05_workload.sql       ← 負荷生成(待機統計の観測) ※23・25・26章で使用
│   └── README.md             ← ER図・テーブル定義
├── docs/                     ← トピック別 T-SQL 仕様解説
│   ├── 00_environment.md
│   ├── 01_select_basics.md
│   └── ...
└── exercises/                ← 演習問題
    ├── 01_select_basics.md
    ├── ...
    └── solutions/            ← 解答例 SQL
        ├── 01_select_basics.sql
        └── ...
```

## カリキュラム一覧

| レベル | # | トピック | 解説 | 演習 |
|---|---|---|---|---|
| 準備 | 00 | 環境準備 | [docs](docs/00_environment.md) | – |
| 基礎 | 01 | SELECT の基礎 | [docs](docs/01_select_basics.md) | [演習](exercises/01_select_basics.md) |
| 基礎 | 02 | WHERE による絞り込み | [docs](docs/02_where_filtering.md) | [演習](exercises/02_where_filtering.md) |
| 基礎 | 03 | 並べ替えとページング | [docs](docs/03_order_paging.md) | [演習](exercises/03_order_paging.md) |
| 結合・集計 | 04 | テーブル結合 (JOIN) | [docs](docs/04_joins.md) | [演習](exercises/04_joins.md) |
| 結合・集計 | 05 | 集計とグループ化 | [docs](docs/05_aggregation.md) | [演習](exercises/05_aggregation.md) |
| 応用 | 06 | サブクエリ | [docs](docs/06_subqueries.md) | [演習](exercises/06_subqueries.md) |
| 応用 | 07 | 共通表式 (CTE) と再帰 | [docs](docs/07_cte.md) | [演習](exercises/07_cte.md) |
| 分析 | 08 | ウィンドウ関数 | [docs](docs/08_window_functions.md) | [演習](exercises/08_window_functions.md) |
| 分析 | 09 | 集合演算 (UNION 等) | [docs](docs/09_set_operations.md) | [演習](exercises/09_set_operations.md) |
| 分析 | 10 | PIVOT / UNPIVOT | [docs](docs/10_pivot_unpivot.md) | [演習](exercises/10_pivot_unpivot.md) |
| 式・関数 | 11 | 条件式と NULL 処理 | [docs](docs/11_conditional_null.md) | [演習](exercises/11_conditional_null.md) |
| 式・関数 | 12 | 組み込み関数 | [docs](docs/12_builtin_functions.md) | [演習](exercises/12_builtin_functions.md) |
| データ操作 | 13 | INSERT / UPDATE / DELETE / MERGE | [docs](docs/13_dml.md) | [演習](exercises/13_dml.md) |
| 実務 | 14 | APPLY (CROSS / OUTER) | [docs](docs/14_apply.md) | [演習](exercises/14_apply.md) |
| 実務 | 15 | 一時テーブルとテーブル変数 | [docs](docs/15_temp_tables.md) | [演習](exercises/15_temp_tables.md) |
| 実務 | 16 | ストアドプロシージャと UDF | [docs](docs/16_stored_procedures.md) | [演習](exercises/16_stored_procedures.md) |
| 実務 | 17 | ユーザー定義型と TVP | [docs](docs/17_user_defined_types.md) | [演習](exercises/17_user_defined_types.md) |
| 性能 | 18 | インデックスと実行プラン | [docs](docs/18_indexes_execution_plans.md) | [演習](exercises/18_indexes_execution_plans.md) |
| 性能 | 19 | トランザクションと分離レベル | [docs](docs/19_transactions_isolation.md) | [演習](exercises/19_transactions_isolation.md) |
| 発展 | 20 | 動的SQL | [docs](docs/20_dynamic_sql.md) | [演習](exercises/20_dynamic_sql.md) |
| 発展 | 21 | 実務頻出クエリパターン集 | [docs](docs/21_query_patterns.md) | [演習](exercises/21_query_patterns.md) |
| 発展 | 22 | JSON操作 | [docs](docs/22_json.md) | [演習](exercises/22_json.md) |
| 診断 | 23 | 待機統計とボトルネック特定 | [docs](docs/23_wait_statistics.md) | [演習](exercises/23_wait_statistics.md) |
| 診断 | 24 | Query Store | [docs](docs/24_query_store.md) | [演習](exercises/24_query_store.md) |
| 診断 | 25 | 拡張イベント | [docs](docs/25_extended_events.md) | [演習](exercises/25_extended_events.md) |
| 診断 | 26 | DMVによる調査 | [docs](docs/26_dmv_investigation.md) | [演習](exercises/26_dmv_investigation.md) |
| 内部 | 27 | 統計情報とカーディナリティ推定 | [docs](docs/27_statistics_cardinality.md) | [演習](exercises/27_statistics_cardinality.md) |
| 内部 | 28 | パラメータスニッフィング詳解 | [docs](docs/28_parameter_sniffing.md) | [演習](exercises/28_parameter_sniffing.md) |
| 内部 | 29 | 結合アルゴリズムと並列処理 | [docs](docs/29_join_algorithms_parallelism.md) | [演習](exercises/29_join_algorithms_parallelism.md) |
| 大規模 | 30 | 列ストアとバッチモード | [docs](docs/30_columnstore.md) | [演習](exercises/30_columnstore.md) |
| 大規模 | 31 | パーティショニング | [docs](docs/31_partitioning.md) | [演習](exercises/31_partitioning.md) |
| 大規模 | 32 | インメモリOLTP | [docs](docs/32_in_memory_oltp.md) | [演習](exercises/32_in_memory_oltp.md) |
| 土台 | 33 | SQL Serverアーキテクチャ | [docs](docs/33_architecture.md) | [演習](exercises/33_architecture.md) |
| 土台 | 34 | テンポラルテーブルと履歴設計 | [docs](docs/34_temporal_tables.md) | [演習](exercises/34_temporal_tables.md) |
| 土台 | 35 | データモデリングと物理設計 | [docs](docs/35_data_modeling.md) | [演習](exercises/35_data_modeling.md) |
| 土台 | 36 | セキュリティ機能 | [docs](docs/36_security.md) | [演習](exercises/36_security.md) |

各トピックの狙いと前提知識は [ROADMAP.md](ROADMAP.md) を参照してください。

### 3つの段階

| 章 | 何を身につけるか |
|---|---|
| **01〜13** | 「**クエリをどう書くか**」= SQL の言語仕様。小さなサンプルデータで文法を学ぶ |
| **14〜22** | 「**実務でどう組み立てるか**」= 一時テーブル・ストアドプロシージャ・TVP・APPLY といった実務コードの骨格と、インデックス/実行プランの基礎 |
| **23〜36** | 「**なぜそうなるかを説明し、直せるか**」= 待機統計とDMVによる診断、オプティマイザ内部、列ストア/パーティション、アーキテクチャと設計 |

> 23章以降は、機能の使い方の暗記ではなく **推測せず計測して切り分ける** ことを主眼にしています。
> 「遅い」を待機統計で特定し、統計情報とプランから原因を説明し、根拠をもって直せる状態を目指します。

### ⚠️ 上級編(23〜36)の作成状況

**解説(docs)は14章すべて揃っています。** 演習と解答は一部が未作成です。
下表の「—」はファイルが存在しないため、カリキュラム表のリンクが切れています。

| 章 | 解説 | 演習 | 解答 |
|---|:--:|:--:|:--:|
| 23 待機統計 / 24 Query Store / 25 拡張イベント / 26 DMV調査 | ✅ | ✅ | ✅ |
| 29 結合アルゴリズム / 30 列ストア | ✅ | ✅ | ✅ |
| 28 パラメータスニッフィング / 31 パーティショニング / 32 インメモリOLTP | ✅ | ✅ | — |
| 27 統計情報とCE / 33 アーキテクチャ / 34 テンポラルテーブル / 35 データモデリング / 36 セキュリティ | ✅ | — | — |

01〜22 は解説・演習・解答がすべて揃っています。

## 対象バージョン

SQL Server 2016 以降を想定しています(`OFFSET-FETCH`、`STRING_SPLIT`、
`STRING_AGG`(2017+)など、バージョン依存の機能は解説内で明記します)。
