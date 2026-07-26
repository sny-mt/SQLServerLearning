# 演習 01 — SELECT の基礎

対象解説: [docs/01_select_basics.md](../docs/01_select_basics.md)
使用DB: `SalesLearning`(先頭で `USE SalesLearning;` を実行しておくこと)

各問、**まず自力でクエリを書いて実行** → 結果を確認 → 解答例
[solutions/01_select_basics.sql](solutions/01_select_basics.sql) と照合しましょう。
解答例と書き方が違っても、同じ結果になっていれば正解です。

---

## 基礎

**Q1.** `Products` テーブルから、商品名(`ProductName`)と単価(`UnitPrice`)の2列を取り出しなさい。

**Q2.** Q1 の結果の見出しを、それぞれ「商品名」「単価」という日本語の別名にしなさい。

**Q3.** `Customers` テーブルに登場する **市(`City`)の一覧** を、重複なく取り出しなさい。

**Q4.** `Employees` テーブルから、姓と名を連結した「氏名」列を作りなさい
(例: `佐藤 太郎` のように姓・名の間は半角スペース)。

---

## 応用

**Q5.** `Products` から、商品名・単価・**税込単価(消費税10%、`UnitPrice * 1.1`)** の
3列を取り出しなさい。税込単価の列見出しは「税込単価」とすること。

**Q6.** `Customers` に登場する **市と地域(`Region`)の組み合わせ** を重複なく取り出しなさい。
(ヒント: `DISTINCT` は選択した列の組み合わせに効く)

**Q7.** `Employees` から、`Email` 列をそのまま取り出しなさい。
結果を見て「NULL になっている社員が何人いるか」を目視で確認しなさい
(絞り込みは次章。ここでは NULL がどう表示されるかを体感するのが目的)。

---

## チャレンジ

**Q8.** 次のクエリはエラーになります。**理由を説明**し、正しく動くよう直しなさい。

```sql
SELECT UnitPrice * 1.1 AS 税込単価
FROM   dbo.Products
WHERE  税込単価 > 10000;
```

**Q9.** `Employees` から、`LastName + FirstName` ではなく `CONCAT` を使って氏名を作り、
`+` 連結と `CONCAT` で NULL の扱いがどう違うかを、`Email` 列を例に確認しなさい
(例: `氏名 + '/' + Email` と `CONCAT(氏名, '/', Email)` を並べて比較)。
