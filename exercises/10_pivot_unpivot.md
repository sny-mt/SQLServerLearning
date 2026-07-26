# 演習 10 — PIVOT / UNPIVOT

対象解説: [docs/10_pivot_unpivot.md](../docs/10_pivot_unpivot.md)
使用DB: `SalesLearning`(先頭で `USE SalesLearning;` を実行しておくこと)

各問、**まず自力でクエリを書いて実行** → 結果を確認 → 解答例
[solutions/10_pivot_unpivot.sql](solutions/10_pivot_unpivot.sql) と照合しましょう。
解答例と書き方が違っても、同じ結果になっていれば正解です。

売上は一貫して `Quantity * UnitPrice * (1 - Discount)` で計算します。
年は `YEAR(OrderDate)`、四半期は `DATEPART(QUARTER, OrderDate)` で求めます。
サンプルの注文は 2023年・2024年に存在します。

---

## 基礎

**Q1.** `PIVOT` を使って「**地域(`Customers.Region`)× 年 の売上**」のクロス集計表を作りなさい。
行が地域、列が `2023` と `2024`、セルが売上合計になるようにすること。
(ヒント: ソースの `SELECT` には「地域・年・売上」の3列だけを書く)

**Q2.** Q1 とまったく同じ結果を、今度は `PIVOT` を使わず
**`SUM(CASE WHEN ...)` の条件付き集計**で作りなさい。

**Q3.** `PIVOT` を使って「**地域 × 年 の注文件数**」のクロス集計を作りなさい。
金額は不要です。1注文を二重に数えないよう、`OrderDetails` は結合しないこと。
(ヒント: 集約関数は `COUNT`)

---

## 応用

**Q4.** `SUM(CASE WHEN ...)` を使って「**カテゴリ(`Categories.CategoryName`)× 年 の売上**」の
クロス集計を作りなさい。列は `2023` と `2024`。
カテゴリ未設定(`CategoryId` が NULL)の商品は集計対象から外してよい
(内部結合すれば自然に除外される)。

**Q5.** Q4 を改良し、**売上が無いセルを NULL ではなく 0 で表示**しなさい。
(ヒント: `COALESCE(SUM(CASE ... END), 0)`)

**Q6.** 次の CTE `横持ち` は「2023年・カテゴリ × 四半期(Q1〜Q4)」の売上を横持ちで持っています。
これを **`UNPIVOT`** で縦持ち(`カテゴリ / 四半期 / 売上` の3列)に変換しなさい。

```sql
WITH 横持ち AS (
    SELECT cat.CategoryName AS カテゴリ,
           SUM(CASE WHEN DATEPART(QUARTER, o.OrderDate)=1
                    THEN od.Quantity*od.UnitPrice*(1-od.Discount) END) AS Q1,
           SUM(CASE WHEN DATEPART(QUARTER, o.OrderDate)=2
                    THEN od.Quantity*od.UnitPrice*(1-od.Discount) END) AS Q2,
           SUM(CASE WHEN DATEPART(QUARTER, o.OrderDate)=3
                    THEN od.Quantity*od.UnitPrice*(1-od.Discount) END) AS Q3,
           SUM(CASE WHEN DATEPART(QUARTER, o.OrderDate)=4
                    THEN od.Quantity*od.UnitPrice*(1-od.Discount) END) AS Q4
    FROM   dbo.OrderDetails AS od
    JOIN   dbo.Orders       AS o   ON o.OrderId     = od.OrderId
    JOIN   dbo.Products     AS p   ON p.ProductId   = od.ProductId
    JOIN   dbo.Categories   AS cat ON cat.CategoryId = p.CategoryId
    WHERE  YEAR(o.OrderDate) = 2023
    GROUP  BY cat.CategoryName
)
-- この下に UNPIVOT を書く
```

売上が NULL の四半期は行として現れない(`UNPIVOT` の仕様)ことも結果で確認しなさい。

---

## チャレンジ

**Q7.** 次の `PIVOT` は「地域 × 年 の売上」を意図していますが、**期待どおりに地域ごとにまとまりません**。
**理由を説明**し、正しく動くように直しなさい。

```sql
SELECT *
FROM (
    SELECT *
    FROM   dbo.Orders o
    JOIN   dbo.Customers c    ON c.CustomerId = o.CustomerId
    JOIN   dbo.OrderDetails od ON od.OrderId = o.OrderId
) AS src
PIVOT ( SUM(od.Quantity * od.UnitPrice * (1 - od.Discount)) FOR ... ) AS pvt;
```

**Q8.** Q6 の横持ち CTE を、今度は **`UNPIVOT` を使わずに `CROSS APPLY (VALUES ...)`** で
縦持ちに変換しなさい。`UNPIVOT` 版(Q6)と比べて、**売上が NULL の四半期の扱いがどう変わるか**を
結果を見て説明しなさい。

**Q9.** 「地域 × 年 の売上」を、対象となる **年を手で書かずに列に展開**したい。
`STRING_AGG` と `sys.sp_executesql` を使った **動的 PIVOT** のクエリを書きなさい
(解説8章の骨子を参考に。`STRING_AGG` は SQL Server 2017 以降)。
