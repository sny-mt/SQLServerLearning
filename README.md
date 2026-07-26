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

各トピックの狙いと前提知識は [ROADMAP.md](ROADMAP.md) を参照してください。

## 対象バージョン

SQL Server 2016 以降を想定しています(`OFFSET-FETCH`、`STRING_SPLIT`、
`STRING_AGG`(2017+)など、バージョン依存の機能は解説内で明記します)。
