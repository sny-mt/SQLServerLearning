# サンプルデータベース `SalesLearning`

本プロジェクトの演習・仕様解説はすべてこの共通スキーマを題材にします。
小規模な販売管理ドメイン(部門・社員・顧客・商品・注文)を模しており、
JOIN・集計・階層・ウィンドウ関数など主要な T-SQL 機能を一通り練習できるよう設計しています。

## セットアップ

SQL Server に接続し、以下を **順番に** 実行してください。

```sql
-- 1. スキーマ作成 (SalesLearning データベースを作り直します)
:r 01_create_schema.sql
-- 2. サンプルデータ投入
:r 02_seed_data.sql
```

- SSMS / Azure Data Studio では各ファイルを開いて実行するだけです。
- `sqlcmd` では以下のように実行できます。

```bash
sqlcmd -S localhost -U sa -P "<password>" -i 01_create_schema.sql
sqlcmd -S localhost -U sa -P "<password>" -i 02_seed_data.sql
```

> ⚠️ `01_create_schema.sql` は既存の `SalesLearning` データベースを **削除して作り直します**。
> 本番環境では実行しないでください。

### 性能編に進むとき(トピック15・18・21)

インデックスや実行プランの学習は、小さなデータでは差が出ません。
性能を扱うトピックに進む前に、追加で次を実行してください。

```sql
:r 03_bulk_data.sql   -- dbo.OrdersBig(100万行)を生成。10〜60秒程度
```

このスクリプトは **既存のテーブルには一切手を触れません**。
性能検証専用の `dbo.OrdersBig` を新しく作るだけなので、
01〜13 の演習結果は変わりません。

### 上級編に進むとき(トピック23以降)

```sql
:r 04_analytics_data.sql   -- dbo.SalesFact(1000万行)。30・31章の列ストア/パーティション用。1〜3分
:r 05_workload.sql         -- 負荷生成スクリプト。23・25・26章の待機統計/ブロッキング観測用
```

- **`04_analytics_data.sql`** … 列ストアのセグメント除外を体感するには、
  データが日付順に並んでいる必要があります(バラバラだと除外が一切効きません)。
  そのため `SaleDate` を `SaleId` に比例させて格納しています。
  重い場合はスクリプト内の `@Total` を `2000000` などに減らせます。
- **`05_workload.sql`** … 待機統計は**同時実行がないと発生しません**。
  複数のクエリウィンドウで別セッションとして実行し、負荷をかけながら観測します。
  全ループに時間制限があり、放置しても自動停止します。書き込み対象は専用表
  `dbo.WorkloadTest` のみで、業務テーブルは変更しません。

## ER 図

```mermaid
erDiagram
    Departments  ||--o{ Employees   : "所属"
    Employees    ||--o{ Employees   : "上司(ManagerId)"
    Employees    ||--o{ Customers   : "担当(SalesRepId)"
    Employees    ||--o{ Orders      : "受注担当"
    Customers    ||--o{ Orders      : "発注"
    Categories   ||--o{ Products    : "分類"
    Orders       ||--o{ OrderDetails: "明細"
    Products     ||--o{ OrderDetails: "商品"

    Departments {
        int          DepartmentId PK
        nvarchar     DepartmentName
        nvarchar     Location
    }
    Employees {
        int          EmployeeId PK
        nvarchar     FirstName
        nvarchar     LastName
        int          DepartmentId FK
        int          ManagerId FK
        date         HireDate
        decimal      Salary
        nvarchar     Email
    }
    Customers {
        int          CustomerId PK
        nvarchar     CustomerName
        nvarchar     City
        nvarchar     Region
        int          SalesRepId FK
    }
    Categories {
        int          CategoryId PK
        nvarchar     CategoryName
    }
    Products {
        int          ProductId PK
        nvarchar     ProductName
        int          CategoryId FK
        decimal      UnitPrice
        bit          Discontinued
    }
    Orders {
        int          OrderId PK
        int          CustomerId FK
        int          EmployeeId FK
        date         OrderDate
        date         ShipDate
    }
    OrderDetails {
        int          OrderId PK,FK
        int          ProductId PK,FK
        int          Quantity
        decimal      UnitPrice
        decimal      Discount
    }
```

## テーブル概要

| テーブル | 説明 | 件数 | 演習で狙うポイント |
|---|---|---:|---|
| `Departments` | 部門マスタ | 5 | 所属社員のいない部門(経理部)で LEFT JOIN / 相関を練習 |
| `Employees` | 社員マスタ | 13 | `ManagerId` の自己参照で自己結合・再帰CTE。`Email`/`DepartmentId` に NULL あり |
| `Categories` | 商品カテゴリ | 5 | 商品との1対多 |
| `Products` | 商品マスタ | 20 | `CategoryId` NULL(未分類)・`Discontinued`(廃番)あり |
| `Customers` | 顧客マスタ | 12 | `SalesRepId` NULL(担当未割当)・注文の無い顧客(ラムダソフト)あり |
| `Orders` | 注文ヘッダ | 20 | `ShipDate` NULL(未出荷)あり。2023〜2024年に分布 |
| `OrderDetails` | 注文明細 | 42 | 複合主キー。`Quantity`・`UnitPrice`・`Discount` で金額計算 |

### 性能検証用テーブル(`03_bulk_data.sql` を実行した場合のみ)

| テーブル | 説明 | 件数 | 演習で狙うポイント |
|---|---|---:|---|
| `OrdersBig` | 性能検証専用の注文データ | 1,000,000 | Seek/Scan の差、SARGability、Key Lookup、統計情報 |

`OrdersBig` の列: `OrderId`(クラスタ化主キー)、`CustomerId`(1〜12)、`EmployeeId`(1〜13)、
`OrderDate`(2015〜2024に分散)、`ShipDate`(約5%がNULL)、`Status`(完了95%/保留5%の偏り)、`Amount`。

**非クラスタ化インデックスは意図的に作っていません。**
トピック18の演習で自分で作り、作成前後の実行プランを比較するためです。

### 分析検証用テーブル(`04_analytics_data.sql` を実行した場合のみ)

| テーブル | 説明 | 件数 | 演習で狙うポイント |
|---|---|---:|---|
| `SalesFact` | 分析用ファクト表 | 10,000,000 | 列ストアの圧縮/セグメント除外、バッチモード、パーティション |

`SalesFact` の列: `SaleId`(クラスタ化主キー)、`SaleDate`(2015〜2024、**SaleIdに比例した日付順**)、
`CustomerId`(1〜1000。合成なので `Customers` とは結合しない)、`ProductId`(1〜20。`Products` と結合可)、
`EmployeeId`、`RegionId`、`Quantity`、`UnitPrice`、`Discount`、`Amount`。

**列ストアインデックスもパーティションも作っていません。**
トピック30・31の演習で自分で作り、行ストアとの差を計測するためです。

### 負荷生成(`05_workload.sql`)

| セクション | 内容 |
|---|---|
| 準備 | `dbo.WorkloadTest`(1000行)を作成 |
| A | 読み取り負荷(60秒)→ `PAGEIOLATCH_SH` / `SOS_SCHEDULER_YIELD` など |
| B | 書き込み負荷(60秒)→ `WRITELOG` / `LCK_M_*` など |
| C | ブロッカー(30秒ロック保持) |
| D | ブロックされる側 |
| E | 観測クエリ(誰が何を待っているか) |
| 後片付け | `dbo.WorkloadTest` を削除 |

## 意図的に仕込んだ「引っかけ」

演習で NULL や境界値の扱いを学べるよう、以下を意図的に用意しています。

- **NULL を含む列**: `Employees.Email`(社員8)、`Employees.DepartmentId`(社員13)、
  `Employees.ManagerId`(社員1=社長)、`Customers.SalesRepId`、`Orders.ShipDate`、`Products.CategoryId`
- **子レコードの無い親**: `Departments`=経理部(社員なし)、`Customers`=ラムダソフト(注文なし)
- **フラグ列**: `Products.Discontinued = 1` の廃番商品(USBハブ・ホチキス)
- **金額計算**: 明細の売上 = `Quantity * UnitPrice * (1 - Discount)`

## 売上金額の考え方

明細1行あたりの売上は次式で求めます(演習で頻出)。

```sql
Quantity * UnitPrice * (1 - Discount) AS LineTotal
```

`Discount` は 0.00〜1.00 の割引率です(例: 0.10 = 10%割引)。
