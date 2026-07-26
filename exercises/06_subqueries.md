# 演習 06 — サブクエリ

対象解説: [docs/06_subqueries.md](../docs/06_subqueries.md)
使用DB: `SalesLearning`(先頭で `USE SalesLearning;` を実行しておくこと)

各問、**まず自力でクエリを書いて実行** → 結果を確認 → 解答例
[solutions/06_subqueries.sql](solutions/06_subqueries.sql) と照合しましょう。
解答例と書き方が違っても、同じ結果になっていれば正解です。

---

## 基礎

**Q1.** `Employees` から、**全社平均給与より給与が高い社員** の姓・名・給与を取り出しなさい。
平均値は手で書かず、スカラーサブクエリで求めること。

**Q2.** `Products` から、**一度でも注文された商品**(`OrderDetails` に登場する `ProductId` を持つ商品)の
商品名を取り出しなさい。`IN` とサブクエリを使うこと。

**Q3.** `Products` から、**廃番商品を除いた商品**(`Discontinued = 1` の `ProductId` 集合を `NOT IN` で除外)の
商品名と単価を取り出しなさい。

**Q4.** `Customers` の各顧客について、顧客名と **その顧客の注文件数** を並べて表示しなさい。
注文件数は `SELECT` 句の中の相関スカラーサブクエリ(`COUNT(*)`)で求めること。
(ヒント: 注文が無い顧客は 0 件になるはず)

---

## 応用

**Q5.** `Customers` から、**一度も注文したことがない顧客** の顧客名と市を、`NOT EXISTS` を使って取り出しなさい。
(該当はラムダソフト1件のはず)

**Q6.** `Employees` から、**各部門で最も給与が高い社員** の姓・部門ID・給与を、相関サブクエリで取り出しなさい。
(ヒント: 内側で「その社員と同じ部門の `MAX(Salary)`」を求めて比較する)

**Q7.** 部門ごとの平均給与を **派生テーブル** にして、そこから **平均給与が 50万円以上の部門** の
部門IDと平均給与を取り出しなさい。部署未定(`DepartmentId IS NULL`)の社員は集計から除くこと。

**Q8.** `Employees` から、**開発部(`DepartmentId = 2`)の誰よりも給与が高い社員** の姓・給与を、
`> ALL` とサブクエリを使って取り出しなさい。

---

## チャレンジ

**Q9.** 次のクエリは「どの顧客の担当営業にもなっていない社員」を出したいものですが、**実行すると0件**になります。
**理由を説明**し、`NOT EXISTS` を使って正しく動くよう直しなさい。

```sql
SELECT e.LastName
FROM   dbo.Employees AS e
WHERE  e.EmployeeId NOT IN (SELECT c.SalesRepId FROM dbo.Customers AS c);
```

**Q10.** `Customers` から、**担当営業(`SalesRepId`)が、その顧客の注文の受注担当(`Orders.EmployeeId`)も務めている顧客**の
顧客名と担当営業IDを、`EXISTS` を使って取り出しなさい。
(ヒント: 内側で `o.CustomerId = c.CustomerId AND o.EmployeeId = c.SalesRepId` を満たす注文の存在を見る)

**Q11.** Q3 と同じ「廃番でない商品」を、今度は **`NOT EXISTS`** で書きなさい。
さらに「**注文明細に一度でも登場した**、廃番でない商品」に条件を強めた版も書きなさい。
