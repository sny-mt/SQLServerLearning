# 演習 20 — 動的SQL

対象解説: [docs/20_dynamic_sql.md](../docs/20_dynamic_sql.md)
使用DB: `SalesLearning`(先頭で `USE SalesLearning;` を実行しておくこと)

各問、**まず自力でクエリを書いて実行** → 結果を確認 → 解答例
[solutions/20_dynamic_sql.sql](solutions/20_dynamic_sql.sql) と照合しましょう。
解答例と書き方が違っても、同じ結果になっていれば正解です。

> ⚠️ **この演習の約束**
> - 実行する前に、必ず `PRINT @sql` か `SELECT @sql` で **生成されたSQLを目視確認** すること。
> - SQL文を入れる変数は **必ず `NVARCHAR(MAX)`** で宣言すること。
> - データを変更する問題は **`BEGIN TRAN` … `ROLLBACK`** で囲むこと(`COMMIT` は絶対にしない)。
> - プロシージャを作る問題は、最後に **`DROP PROCEDURE IF EXISTS`** で必ず後片付けすること。
> - 値は原則 **パラメータ**、識別子は **`QUOTENAME` + ホワイトリスト検証**。

---

## 基礎

**Q1.** `dbo.Products` の `ProductId` / `ProductName` / `UnitPrice` を `ProductId` 順に取り出す
SELECT文を、`NVARCHAR(MAX)` の変数に組み立てなさい。
実行の前に `PRINT` と `SELECT` の両方で生成SQLを表示し、そのうえで `sys.sp_executesql` で実行しなさい。

**Q2.** Q1 のクエリに「カテゴリで絞り込む」条件を追加しなさい。
カテゴリID は変数 `@CategoryId`(値は 1)で与え、**文字列に連結せず `sp_executesql` のパラメータとして渡す**こと。
並び順は単価の降順とします。

**Q3.** 顧客ID を渡すと、その顧客の **注文件数** と **売上合計**
(`Quantity * UnitPrice * (1 - Discount)` の合計)を返す動的SQLを書きなさい。
2つの値は **OUTPUT パラメータ**で呼び出し元の変数に受け取り、最後に `SELECT` で表示すること。
顧客ID は 1 で試しなさい。
(ヒント: 注文件数は明細との結合で重複するので `COUNT(DISTINCT o.OrderId)`)

**Q4.** 「顧客名で `dbo.Customers` を検索する」処理を、次の2通りで書いて比較しなさい。

1. 検索文字列を **文字列連結** で埋め込む危険な版(`EXEC()` で実行)
2. **`sp_executesql` のパラメータ**で渡す安全な版

そのうえで、検索文字列に `' OR 1 = 1 --`(先頭がシングルクォート)を与えて両方を実行し、
**結果件数がどう変わるか**を確認しなさい。危険な版では何が起きているのか、
生成SQLを `PRINT` して説明しなさい。

---

## 応用

**Q5.** `dbo.Products` を、**実行時に指定された列**で並べ替えて返す動的SQLを書きなさい。
並べ替え列は変数 `@SortColumn`、方向は `@SortDir`(`ASC` / `DESC`)で与えます。

- 許可する列は `ProductId` / `ProductName` / `UnitPrice` の3つだけ。
  それ以外が指定されたら `THROW` でエラーにすること(**ホワイトリスト検証**)。
- 方向も `ASC` / `DESC` 以外は弾くこと。
- 列名は必ず **`QUOTENAME()`** を通して連結すること。
- `@SortColumn = N'UnitPrice'`, `@SortDir = N'DESC'` で動作確認したあと、
  `@SortColumn = N'Salary'` のような許可外の値でエラーになることも確認しなさい。

**Q6.** `dbo.Customers` を、`@City` / `@Region` / `@SalesRepId` の3つで検索する動的SQLを書きなさい。
**NULL でない引数の条件だけ** を `WHERE` に組み立てること。

- `WHERE 1 = 1` から始め、`IF ... SET @sql += ...` で条件を追加する。
- 値は必ず `sp_executesql` のパラメータで渡す(連結しない)。
- `@City = N'東京'` のみ指定、`@Region = N'関西'` のみ指定、全部 NULL の3パターンで
  生成SQLと結果を確認しなさい。

**Q7.** Q6 とまったく同じ要件を、**動的SQLを使わずに**
`WHERE (@City IS NULL OR City = @City) AND ...` の形で書きなさい。
さらに `OPTION (RECOMPILE)` を付けた版も書き、
「この方式の何が問題で、`OPTION (RECOMPILE)` が何を解決するのか」を
コメントで説明しなさい。

**Q8.** テーブル名を変数 `@TableName` で受け取り、そのテーブルの **行数** を
OUTPUT パラメータで返す動的SQLを書きなさい。

- `OBJECT_ID` で **実在するユーザーテーブルかを検証**してから連結すること。
- テーブル名は `QUOTENAME()` を通すこと。
- `N'Orders'` と `N'OrderDetails'` で確認し、`N'NotExists'` でエラーになることも確認しなさい。

---

## チャレンジ

**Q9.** 10章で宿題になっていた **動的 PIVOT** を完成させなさい。
`dbo.Orders` に実在する年を自動で列見出しにして、**地域(`Customers.Region`)× 年 の売上**の
クロス集計を出力しなさい。

- 列リストは `QUOTENAME` + **`STRING_AGG`**(SQL Server 2017 以降)で組み立てること。
- 年の並び順が安定するよう `WITHIN GROUP (ORDER BY ...)` を付けること。
- `PIVOT` のソースは「地域 / 年 / 売上」の **3列だけ**にすること(10章3節の鉄則)。
- 実行前に生成SQLを `PRINT` すること。

**Q10.** Q9 の列リストの組み立てを、`STRING_AGG` が使えない環境(SQL Server 2016)向けに
**`FOR XML PATH` + `STUFF`** で書き直しなさい。生成される列リスト文字列が
Q9 と同じ(`[2023], [2024]`)になることを確認しなさい。

**Q11.** 「**カテゴリ × 年 の売上**」の動的 PIVOT を、ストアドプロシージャ
`dbo.usp_SalesPivotByCategory` にまとめなさい。

- 引数 `@Debug BIT = 0` を持ち、`1` のときは実行せず生成SQLを `PRINT` するだけにすること。
- カテゴリ未設定の商品(`CategoryId` が NULL の 高級万年筆・ノベルティグッズ)は
  `N'(未分類)'` として1行にまとめること。
- 空セルは NULL のままでよい。
- `@Debug = 1` と `@Debug = 0` の両方で動作確認したあと、
  **`DROP PROCEDURE IF EXISTS` で必ず後片付け**すること。

**Q12.** 動的SQLの **スコープ**を実験で確かめなさい。次の (a)〜(e) を順に実行し、
それぞれの結果(またはエラー)をコメントで説明しなさい。

- (a) 呼び出し元で作った一時テーブル `#Scope` を、動的SQLの中から `SELECT` できるか
- (b) 呼び出し元のローカル変数 `@v` を、動的SQLの中から参照できるか
- (c) (b) が失敗する場合、値を渡すにはどうすればよいか
- (d) 動的SQLの**中で** `CREATE TABLE #Inner` したテーブルは、動的SQLが終わったあと外から見えるか
- (e) 動的SQLの中から `#Scope` に `INSERT` した結果は、呼び出し元に反映されるか

最後に `#Scope` を `DROP TABLE` して片付けること。

**Q13.** 商品ID `2`(ワイヤレスマウス)の単価を 10% 値下げする `UPDATE` を、
**動的SQL + パラメータ化**で実行しなさい。

- 商品IDと値下げ率は `sp_executesql` のパラメータで渡すこと。
- 実行前に生成SQLを `PRINT` し、実行後に該当行を `SELECT` で確認すること。
- **全体を `BEGIN TRAN` … `ROLLBACK` で囲み、変更を必ず取り消すこと**。
