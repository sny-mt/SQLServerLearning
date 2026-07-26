# 演習 09 — 集合演算 (UNION など)

対象解説: [docs/09_set_operations.md](../docs/09_set_operations.md)
使用DB: `SalesLearning`(先頭で `USE SalesLearning;` を実行しておくこと)

各問、**まず自力でクエリを書いて実行** → 結果を確認 → 解答例
[solutions/09_set_operations.sql](solutions/09_set_operations.sql) と照合しましょう。
解答例と書き方が違っても、同じ結果になっていれば正解です。

---

## 基礎

**Q1.** 東京にある顧客の名称(`Customers.CustomerName`、`City = N'東京'`)と、
東京にある部門の名称(`Departments.DepartmentName`、`Location = N'東京'`)を、
**縦に1列** で並べなさい。重複は気にしなくてよい(そのまま連結する演算子を使う)。

**Q2.** `Customers` に登場する市(`City`)と、`Departments` に登場する所在地(`Location`)を
**1つの列にまとめ、重複を除いて** 一覧にしなさい。

**Q3.** Q2 を `UNION ALL` に変えると結果がどう変わるか実行して確かめ、
`UNION` と `UNION ALL` の違い(重複排除の有無)を1〜2行で説明しなさい。

---

## 応用

**Q4.** 担当営業が付いている顧客(`SalesRepId IS NOT NULL`)の **担当社員Id** と、
担当が付いていない顧客(`SalesRepId IS NULL`)を、次の形で縦に並べなさい。
1列目に社員Idまたは `NULL`、2列目に区分ラベル(`N'担当あり'` / `N'担当なし'`)を出すこと。
(ヒント: 各 `SELECT` に固定文字列の列を足す)

**Q5.** 一度でも注文したことがある顧客の `CustomerId` と、
まったく注文したことがない顧客の `CustomerId` を、それぞれ求めなさい。
「注文なし」は **`EXCEPT` を使って** 全顧客から注文実績のある顧客を引いて求めること。

**Q6.** 顧客の担当社員(`Customers.SalesRepId`、NULL除く)と、
注文を受注した社員(`Orders.EmployeeId`、NULL除く)の **両方に現れる社員Id** を、
`INTERSECT` を使って求めなさい。

**Q7.** Q1 の結果を、名称の昇順に並べ替えなさい。
(ヒント: `ORDER BY` は全体の末尾に1つだけ。先頭 `SELECT` の列名か位置番号で指定)

---

## チャレンジ

**Q8.** 次のクエリはエラーになります。**理由を説明**し、正しく動くよう直しなさい。

```sql
SELECT CustomerName, City FROM dbo.Customers WHERE City = N'東京'
UNION ALL
SELECT DepartmentName FROM dbo.Departments WHERE Location = N'東京';
```

**Q9.** Q5 の「注文なし顧客」を、今度は **`NOT EXISTS`** を使って
`CustomerId` と `CustomerName` の2列で求めなさい。
`EXCEPT` 版と `NOT EXISTS` 版で、それぞれどんなときに向くかを一言添えなさい。

**Q10.** 集合演算での NULL の扱いを確かめます。
`Customers.SalesRepId`(担当NULLの顧客が複数いる)の一覧に対し `UNION` を使って
`NULL` を1行足したとき、結果に `NULL` が **いくつ** 現れるかを予想し、実行して確認しなさい。
そのうえで「集合演算では `NULL` どうしが同一とみなされる」ことを説明しなさい。
