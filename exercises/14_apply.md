# 演習 14 — APPLY (CROSS APPLY / OUTER APPLY)

対象解説: [docs/14_apply.md](../docs/14_apply.md)
使用DB: `SalesLearning`(先頭で `USE SalesLearning;` を実行しておくこと)

各問、**まず自力でクエリを書いて実行** → 結果を確認 → 解答例
[solutions/14_apply.sql](solutions/14_apply.sql) と照合しましょう。
解答例と書き方が違っても、同じ結果になっていれば正解です。

売上・金額は一貫して `Quantity * UnitPrice * (1 - Discount)` で計算します。
`TOP` を使うときは **必ず `ORDER BY`** を書き、並べ替えキーが同値になり得る場合は
`OrderId` などを足して一意にすること。

Q12 では関数を作成します。**最後に `DROP FUNCTION` まで実行**して後片付けすること。

---

## 基礎

**Q1.** `CROSS APPLY` を使って、**各顧客の最新の注文1件**(顧客名・注文Id・注文日)を取り出しなさい。
最新は `OrderDate` の降順で判定すること。
(ヒント: 右辺に `SELECT TOP (1) ... WHERE o.CustomerId = c.CustomerId ORDER BY ...`)

**Q2.** Q1 を `OUTER APPLY` に変えて実行し、**結果の行数がどう変わるか**を確認しなさい。
増えた行はどの顧客か、なぜ `CROSS APPLY` では出てこなかったのかを説明しなさい。

**Q3.** `CROSS APPLY` を使って、**カテゴリごとに単価が高い商品2件**
(カテゴリ名・商品名・単価)を取り出しなさい。
`CategoryId` が NULL の商品は結果に出てこないはずです。理由も考えてみましょう。

**Q4.** `OUTER APPLY` を使って、顧客ごとに **最終注文日・初回注文日・注文件数** の3つを
**1つの右辺から**まとめて取り出しなさい(顧客名も表示)。
注文が1件も無い顧客も結果に残すこと。
(ヒント: 右辺は `GROUP BY` の無い集約だけの `SELECT`)

---

## 応用

**Q5.** `APPLY` を2段に重ねて、**顧客ごとの最新注文3件**と、
**その注文の明細合計金額**(`Quantity * UnitPrice * (1 - Discount)` の合計)を1つのクエリで出しなさい。
列は 顧客名・注文Id・注文日・合計金額。
(ヒント: 2つ目の `APPLY` からは、1つ目の `APPLY` の結果も参照できる)

**Q6.** Q3 とまったく同じ結果を、今度は `APPLY` を使わず
**`ROW_NUMBER()` と CTE** で書きなさい。
書き終えたら、Q3 の APPLY 版と比べて **構造がどう違うか**(CTE の要否、
親テーブルの扱い、全カテゴリを残したい場合にどちらが楽か)を説明しなさい。

**Q7.** `CROSS APPLY (VALUES ...)` を使って、**注文1001の各明細**を
「単価」「数量」「金額」の **3行に展開**しなさい。
結果の列は 注文Id・商品Id・項目・値 の4列とすること。
(ヒント: 右辺の別名は `AS v(項目, 値)` のように列名まで書く。値の型は `CAST` で揃える)

**Q8.** 次のクエリは同じ式を3回書いていて冗長です。
`CROSS APPLY (VALUES ...)` を使って **式を1か所にまとめ**、同じ結果を出しなさい。

```sql
SELECT od.OrderId,
       od.ProductId,
       od.Quantity * od.UnitPrice * (1 - od.Discount)         AS 金額,
       od.Quantity * od.UnitPrice * (1 - od.Discount) * 0.1   AS 消費税,
       od.Quantity * od.UnitPrice * (1 - od.Discount) * 1.1   AS 税込金額
FROM   dbo.OrderDetails AS od;
```

---

## チャレンジ

**Q9.** 次のクエリはエラーになります。**エラーになる理由を説明**し、
`APPLY` を使って動くように直しなさい。

```sql
SELECT c.CustomerName, x.OrderId, x.OrderDate
FROM   dbo.Customers AS c
JOIN   (SELECT TOP (3) o.OrderId, o.OrderDate
        FROM   dbo.Orders AS o
        WHERE  o.CustomerId = c.CustomerId
        ORDER  BY o.OrderDate DESC) AS x
       ON 1 = 1;
```

また、「`TOP (3)` を派生テーブルの外側に出す」という直し方では
**要件を満たせない理由**もあわせて説明しなさい。

**Q10.** `Employees` は `ManagerId` で自己参照しています。
`OUTER APPLY` を使って、**各社員について「自分の直属の部下のうち給与が高い順に2名」**を
取り出しなさい(上司の氏名・部下の氏名・部下の給与)。
**部下が1人もいない社員も結果に残す**こと。

**Q11.** 注文ごとの商品Idを `STRING_AGG` でカンマ区切りの1文字列にまとめ、
それを `CROSS APPLY STRING_SPLIT(...)` で **再び行に展開**しなさい
(注文Id・商品IDリスト・展開後の商品Id を並べて表示)。
なぜここで `JOIN` ではなく `APPLY` が必要なのかも説明しなさい。
(`STRING_SPLIT` は SQL Server 2016 以降、`STRING_AGG` は 2017 以降)

**Q12.** 「指定した顧客の直近 N 件の注文を返す」**インラインテーブル値関数**
`dbo.fn_顧客直近注文(@CustomerId, @N)` を作り、
`CROSS APPLY` で全顧客に対して直近2件を取り出しなさい。
確認できたら **`DROP FUNCTION` で後片付け**すること。
(関数の詳しい作り方は [16 ストアドプロシージャとユーザー定義関数](../docs/16_stored_procedures.md) で扱います。
ここでは `RETURNS TABLE ... RETURN (SELECT ...)` の形をなぞれば十分です)
