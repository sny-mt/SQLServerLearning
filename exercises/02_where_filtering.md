# 演習 02 — WHERE による絞り込み

対象解説: [docs/02_where_filtering.md](../docs/02_where_filtering.md)
前提: [docs/01_select_basics.md](../docs/01_select_basics.md)
使用DB: `SalesLearning`(先頭で `USE SalesLearning;` を実行しておくこと)

各問、**まず自力でクエリを書いて実行** → 結果を確認 → 解答例
[solutions/02_where_filtering.sql](solutions/02_where_filtering.sql) と照合しましょう。
解答例と書き方が違っても、同じ結果になっていれば正解です。

---

## 基礎

**Q1.** `Products` から、単価(`UnitPrice`)が **10000 円以上** の商品の商品名と単価を取り出しなさい。

**Q2.** `Employees` から、給与(`Salary`)が **60万円ちょうどではない** 社員の姓・名・給与を取り出しなさい。

**Q3.** `Products` から、単価が **1000 円以上 5000 円以下**(両端含む)の商品を、`BETWEEN` を使って取り出しなさい。

**Q4.** `Employees` から、部署(`DepartmentId`)が **1・2・3 のいずれか** に所属する社員を、`IN` を使って取り出しなさい。

**Q5.** `Products` から、商品名が **「ノート」で始まる** 商品を `LIKE` を使って取り出しなさい。
(ヒント: 日本語リテラルには `N` を付ける)

---

## 応用

**Q6.** `Employees` から、**「営業部(1)または開発部(2)」かつ「給与 50万円以上」** の社員を取り出しなさい。
`AND`/`OR` の優先順位に注意し、**括弧** で意図を固定すること。

**Q7.** `Employees` から、**`Email` が未登録(NULL)** の社員を取り出しなさい。
`= NULL` では取れないことも確認しなさい(なぜ取れないか説明できるとなおよい)。

**Q8.** `Customers` から、**担当営業(`SalesRepId`)が割り当てられていない** 顧客を取り出しなさい。

**Q9.** `Products` から、**カテゴリ未分類(`CategoryId` が NULL)** の商品を取り出しなさい。

**Q10.** `Customers` から、市(`City`)に **「東」を含む** 顧客を `LIKE` で取り出しなさい。

---

## チャレンジ

**Q11.** 次のクエリは意図どおりに動きません。**理由を説明**し、正しく直しなさい。
意図は「営業部または開発部で、かつ給与 50万円以上」です。

```sql
SELECT LastName, DepartmentId, Salary
FROM   dbo.Employees
WHERE  DepartmentId = 1 OR DepartmentId = 2 AND Salary >= 500000;
```

**Q12.** 次のクエリは **1件も返りません**。理由(NULL と三値論理)を説明し、
「担当営業が 2 でも 3 でもない顧客」を正しく取得できるよう直しなさい。
さらに **担当が未割り当て(NULL)の顧客も結果に含める** 版も書きなさい。

```sql
SELECT CustomerName, SalesRepId
FROM   dbo.Customers
WHERE  SalesRepId NOT IN (2, 3, NULL);
```

**Q13.** `Customers` から、**一度も注文していない顧客** を取り出しなさい。
`NOT IN (サブクエリ)` ではなく `NOT EXISTS` を使い、なぜ NULL に強いのかを説明しなさい。
(ヒント: `Orders` テーブルの `CustomerId` と突き合わせる。該当は「ラムダソフト」)

**Q14.** `Employees` から、**姓が「佐」または「山」で始まる** 社員を、`LIKE` の
文字クラス `[ ]` を使って **1つの条件** で取り出しなさい。
(ヒント: `LIKE N'[佐山]%'`)
