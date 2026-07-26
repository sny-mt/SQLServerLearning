# 演習 04 — テーブル結合 (JOIN)

対象解説: [docs/04_joins.md](../docs/04_joins.md)
使用DB: `SalesLearning`(先頭で `USE SalesLearning;` を実行しておくこと)

各問、**まず自力でクエリを書いて実行** → 結果を確認 → 解答例
[solutions/04_joins.sql](solutions/04_joins.sql) と照合しましょう。
解答例と書き方が違っても、同じ結果になっていれば正解です。

---

## 基礎

**Q1.** `Employees` と `Departments` を `INNER JOIN` で結び、
社員の姓(`LastName`)と所属部署名(`DepartmentName`)の一覧を出しなさい。
テーブルには別名(`e`, `d` など)を付けること。

**Q2.** `Products` と `Categories` を `INNER JOIN` で結び、
商品名(`ProductName`)とカテゴリ名(`CategoryName`)を出しなさい。
カテゴリが未設定の商品(高級万年筆・ノベルティグッズ)が結果に **現れないこと** を確認しなさい。

**Q3.** Q1 を `LEFT JOIN` に変え、**すべての社員** を残しなさい。
部署が未設定の社員(佐々木彩)が、部署名 NULL で現れることを確認しなさい。

**Q4.** `Departments` を左に、`Employees` を右に `LEFT JOIN` して、
**すべての部署** を残しなさい。所属社員のいない **経理部** が現れることを確認しなさい。
(ヒント: `FROM dbo.Departments AS d LEFT JOIN dbo.Employees AS e ON ...`)

---

## 応用

**Q5.** 顧客(`Customers`)と担当営業を結びなさい。
`Customers.SalesRepId` を `Employees.EmployeeId` に突き合わせ、
顧客名と担当営業の姓を出しなさい。担当が未設定の顧客(イオタ商会・ラムダソフト)も
`LEFT JOIN` で残し、担当欄は `(担当未設定)` と表示すること。

**Q6.** 注文・顧客・受注担当社員の3テーブルを結び、
`OrderId`・注文日(`OrderDate`)・顧客名・受注担当社員の姓を、`OrderId` 順に出しなさい。

**Q7.** 注文明細の売上一覧を作りなさい。`Orders`・`Customers`・`OrderDetails`・`Products`
の4テーブルを結び、`OrderId`・顧客名・商品名・**明細売上**
(`Quantity * UnitPrice * (1 - Discount)`)を出しなさい。

**Q8.** `Employees` を自己結合して、社員の姓と **その上司の姓** を並べなさい。
上司のいない社長(佐藤太郎)も残すこと(ヒント: 上司は `ManagerId` → `EmployeeId`)。

---

## チャレンジ

**Q9.** **注文が1件もない顧客** の顧客名だけを抽出しなさい。
(ヒント: `Customers LEFT JOIN Orders` して、`Orders` 側が NULL の行に絞る)

**Q10.** 次の2つのクエリは、片方だけ「注文のない顧客」を結果に含みます。
それぞれの結果の違いを述べ、**なぜそうなるか** を説明しなさい。

```sql
-- (A)
SELECT c.CustomerName, o.OrderId, o.ShipDate
FROM   dbo.Customers AS c
LEFT JOIN dbo.Orders AS o
       ON c.CustomerId = o.CustomerId
      AND o.ShipDate IS NOT NULL;

-- (B)
SELECT c.CustomerName, o.OrderId, o.ShipDate
FROM   dbo.Customers AS c
LEFT JOIN dbo.Orders AS o
       ON c.CustomerId = o.CustomerId
WHERE  o.ShipDate IS NOT NULL;
```

**Q11.** `Departments` と `Employees` を `FULL OUTER JOIN` して、
「社員のいない部署」と「部署のない社員」の **両方** が1つの結果に現れることを確認しなさい。
部署名または社員名が NULL の行に注目すること。
