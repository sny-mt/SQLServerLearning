# 00 環境準備

演習を始めるには、(1) SQL Server 本体 と (2) クエリを実行するクライアント が必要です。
手元の環境に合わせていずれかを選んでください。

## 1. SQL Server を用意する

### 選択肢A: Docker で動かす(手軽・推奨)

Docker があれば OS を問わず数分で用意できます。

```bash
docker run -e "ACCEPT_EULA=Y" -e "MSSQL_SA_PASSWORD=Your_password123" \
  -p 1433:1433 --name mssql -d mcr.microsoft.com/mssql/server:2022-latest
```

- 接続先: `localhost,1433` / ユーザー `sa` / パスワードは上で指定したもの。
- パスワードは既定で「8文字以上・大文字/小文字/数字/記号のうち3種類」が必要です。

### 選択肢B: Windows にインストール

[SQL Server Developer Edition](https://www.microsoft.com/sql-server/sql-server-downloads)
(無償・フル機能)をインストールします。学習用途にはこれが最適です。

### 選択肢C: Azure SQL Database

クラウドで試すなら Azure SQL Database の無料枠も利用できます。
一部の機能・構文に差異があるため、本プロジェクトはオンプレ/コンテナの
SQL Server を基準にしています。

## 2. クライアントツールを用意する

| ツール | 対応OS | 備考 |
|---|---|---|
| **SQL Server Management Studio (SSMS)** | Windows | 定番。実行プラン表示が強力 |
| **Azure Data Studio** | Windows / macOS / Linux | 軽量・クロスプラットフォーム |
| **VS Code + mssql 拡張** | Windows / macOS / Linux | 普段 VS Code を使う人向け |
| **sqlcmd** | 各OS | CLI。スクリプト実行に便利 |

## 3. サンプルデータベースを構築する

本プロジェクトの題材データベース `SalesLearning` を作成します。

1. クライアントで SQL Server に接続する。
2. [`sample-db/01_create_schema.sql`](../sample-db/01_create_schema.sql) を実行(スキーマ作成)。
3. [`sample-db/02_seed_data.sql`](../sample-db/02_seed_data.sql) を実行(データ投入)。

`sqlcmd` の場合:

```bash
sqlcmd -S localhost -U sa -P "Your_password123" -i sample-db/01_create_schema.sql
sqlcmd -S localhost -U sa -P "Your_password123" -i sample-db/02_seed_data.sql
```

構築できたら、以下で動作確認します。

```sql
USE SalesLearning;
SELECT COUNT(*) AS 社員数 FROM dbo.Employees;   -- 13 が返れば OK
```

テーブル構成・ER図は [`sample-db/README.md`](../sample-db/README.md) を参照してください。

## 4. これだけは覚えておきたい操作

- **バッチ区切り `GO`**: 複数の文をまとめて送るときの区切り。`GO` 自体は T-SQL ではなく
  クライアント(SSMS/sqlcmd)の命令です。
- **選択実行**: SSMS/ADS では実行したい範囲を選択して `F5`(または実行ボタン)。
- **実行プラン表示**: SSMS で `Ctrl+M` を押してからクエリを実行すると、
  「実際の実行プラン」タブが表示され、内部でどう処理されたか可視化できます。

準備ができたら [01 SELECT の基礎](01_select_basics.md) へ進みましょう。
