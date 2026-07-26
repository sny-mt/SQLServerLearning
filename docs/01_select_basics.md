# 01 SELECT の基礎

> **このトピックのゴール**: 1つのテーブルから欲しい列を取り出し、別名を付け、
> 重複を除き、計算列を作れるようになる。
>
> **前提**: [00 環境準備](00_environment.md) を済ませ、`SalesLearning` を構築済みであること。

すべての例は先頭で `USE SalesLearning;` を実行済みとします。

## 1. もっとも基本の形

```sql
SELECT ProductName, UnitPrice
FROM   dbo.Products;
```

- `SELECT` … 取り出す **列** を指定する。
- `FROM`  … 取り出す **テーブル** を指定する。
- 文の終わりは `;`(セミコロン)。SQL Server では省略可能な場面もありますが、
  **常に付ける**ことを習慣にしましょう。

### スキーマ修飾名 `dbo.`

`dbo.Products` の `dbo` は **スキーマ名** です。`Products` だけでも動きますが、
所有スキーマを明示すると解決が速く・曖昧さがなくなるため、本プロジェクトでは
`dbo.` を付けて書きます。

## 2. 全列を取り出す `*`

```sql
SELECT * FROM dbo.Products;
```

`*` は「全列」を意味します。動作確認には便利ですが、**本番のクエリでは避ける**のが定石です。

- 必要以上の列を転送してしまう(遅い)。
- テーブル定義が変わると結果の列構成が勝手に変わる。
- 何を取っているのか読み手に伝わらない。

## 3. 列に別名を付ける `AS`

結果の見出し(列名)を分かりやすく変えられます。

```sql
SELECT ProductName AS 商品名,
       UnitPrice   AS 単価
FROM   dbo.Products;
```

- `AS` は省略できます(`UnitPrice 単価`)が、**付けたほうが読みやすい**です。
- 別名に空白や記号を含めたいときは角括弧で囲みます: `AS [税抜 単価]`。

## 4. 計算列(式を SELECT に書く)

`SELECT` には列だけでなく **式** も書けます。

```sql
SELECT ProductName,
       UnitPrice,
       UnitPrice * 1.1 AS 税込単価      -- 消費税10%
FROM   dbo.Products;
```

文字列の連結には `+` を使います(または `CONCAT` 関数)。

```sql
SELECT LastName + N' ' + FirstName AS 氏名
FROM   dbo.Employees;
```

> ⚠️ `+` による連結は、**片方が NULL だと結果全体が NULL** になります。
> NULL があり得る列を連結するときは `CONCAT`(NULL を空文字として扱う)が安全です。
> 詳細は [11 条件式と NULL 処理](11_conditional_null.md)。

## 5. 重複を取り除く `DISTINCT`

```sql
SELECT DISTINCT City
FROM   dbo.Customers;
```

`DISTINCT` は **行全体(選択した列の組み合わせ)** の重複を除きます。

```sql
-- City と Region の「組み合わせ」でユニークにする
SELECT DISTINCT City, Region
FROM   dbo.Customers;
```

## 6. リテラルと定数列

固定値の列を混ぜることもできます。ラベル付けなどに使います。

```sql
SELECT ProductName,
       UnitPrice,
       N'円' AS 通貨単位
FROM   dbo.Products;
```

- 文字列リテラルはシングルクォート `'...'` で囲みます。
- **日本語などの Unicode 文字列** は先頭に `N` を付けて `N'...'` とします
  (`N` は nvarchar リテラルの意味。付けないと文字化けの原因になります)。

## 7. 論理的な評価順序(超重要)

SQL は書く順序と **評価される順序が違います**。この感覚が後々効いてきます。

| 記述順 | 評価順 | 句 |
|---|---|---|
| 1 | 5 | `SELECT` |
| 2 | 1 | `FROM` |
| 3 | 2 | `WHERE` |
| 4 | 3 | `GROUP BY` |
| 5 | 4 | `HAVING` |
| 6 | 6 | `ORDER BY` |

ここから分かる重要な帰結:

- **`SELECT` で付けた別名は `WHERE`/`GROUP BY`/`HAVING` では使えない**
  (それらの句のほうが先に評価されるため)。`ORDER BY` でだけ別名が使えます。

```sql
-- ✗ エラー: WHERE では別名 税込単価 を参照できない
SELECT UnitPrice * 1.1 AS 税込単価
FROM   dbo.Products
WHERE  税込単価 > 10000;

-- ○ 式をそのまま書くか、後述のサブクエリ/CTEを使う
SELECT UnitPrice * 1.1 AS 税込単価
FROM   dbo.Products
WHERE  UnitPrice * 1.1 > 10000;
```

## 8. コメントの書き方

```sql
-- 行コメント(この行の末尾まで)

/* ブロックコメント
   複数行に渡って書ける */
```

## よくあるつまずき

- **日本語が `?` になる** → 文字列リテラルに `N` を付け忘れている(`N'東京'`)。
- **連結結果が空(NULL)になる** → 連結対象に NULL 列がある。`CONCAT` を使う。
- **`WHERE` で別名が使えない** → 評価順序のため。式を直接書くか CTE/サブクエリへ。
- **`SELECT *` のまま提出** → 必要な列だけを明示する癖をつける。

## この章のまとめ

- `SELECT 列 FROM テーブル` が基本形。`*` は学習・確認用にとどめる。
- `AS` で別名、式で計算列、`DISTINCT` で重複排除。
- 日本語リテラルは `N'...'`。
- **論理評価順序**(`FROM`→`WHERE`→…→`SELECT`→`ORDER BY`)を意識すると、
  別名やエラーの理由が腑に落ちる。

➡ 演習: [exercises/01_select_basics.md](../exercises/01_select_basics.md)
