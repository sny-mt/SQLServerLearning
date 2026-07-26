# 演習 05 — 集計とグループ化

対象解説: [docs/05_aggregation.md](../docs/05_aggregation.md)
使用DB: `SalesLearning`(先頭で `USE SalesLearning;` を実行しておくこと)

各問、**まず自力でクエリを書いて実行** → 結果を確認 → 解答例
[solutions/05_aggregation.sql](solutions/05_aggregation.sql) と照合しましょう。
解答例と書き方が違っても、同じ結果になっていれば正解です。

---

## 基礎

**Q1.** `Employees` テーブル全体について、**社員数・給与の合計・平均・最低・最高** を
1行で求めなさい(`COUNT`/`SUM`/`AVG`/`MIN`/`MAX`)。見出しは日本語の別名を付けること。

**Q2.** `Orders` から、**最も古い注文日** と **最も新しい注文日** を求めなさい
(`MIN`/`MAX` は日付にも使える)。

**Q3.** `Employees` について、次の4つを1つのクエリで求め、値の違いを確認しなさい。
`COUNT(*)`(全社員)、`COUNT(Email)`(Email がある人数)、
`COUNT(DepartmentId)`(部署が設定されている人数)、
`COUNT(DISTINCT DepartmentId)`(部署の種類数)。
それぞれの数がなぜその値になるか、コメントで説明できるようにすること。

**Q4.** `Employees` を **部署(`DepartmentId`)ごと** にまとめ、
各部署の **人数** と **平均給与** を求めなさい。

**Q5.** `Products` を **カテゴリ(`CategoryId`)ごと** にまとめて商品数を数えなさい。
`CategoryId` が NULL の商品(未分類)がどう扱われるかを確認すること。

---

## 応用

**Q6.** Q5 を改良し、`CategoryId` が NULL の行の見出しが「未分類」と表示されるようにしなさい
(ヒント: `ISNULL` と `CAST`、または `CASE`)。

**Q7.** 部署ごとの平均給与を求め、**平均給与が 50万(500000)を超える部署だけ** を残しなさい。
また、部署が未設定(`DepartmentId` が NULL)の社員は **集計に含めない** こと
(ヒント: 集計前の除外は `WHERE`、集計後の絞り込みは `HAVING`)。

**Q8.** `Orders` と `OrderDetails` を結合し、**顧客(`CustomerId`)ごとの売上合計** を求め、
売上の高い順に並べなさい。明細金額は `Quantity * UnitPrice * (1 - Discount)` で計算すること。

**Q9.** `Orders` と `OrderDetails` を結合し、**年・月ごとの売上** と **注文件数** を求めなさい。
注文件数は「注文の数」であって「明細行の数」ではない点に注意すること
(ヒント: `COUNT(DISTINCT OrderId)`)。年・月の昇順で並べること。

**Q10.** 次のクエリはエラーになります。**理由を説明**し、意図(部署ごとの平均給与を出す)
どおりに動くよう直しなさい。

```sql
SELECT DepartmentId, LastName, AVG(Salary) AS 平均給与
FROM   dbo.Employees
GROUP  BY DepartmentId;
```

---

## チャレンジ

**Q11.** `Customers` を **地域(`Region`)× 担当(`SalesRepId`)** で集計して顧客数を求め、
`ROLLUP` を使って **地域ごとの小計** と **全体総計** も同時に出しなさい。

**Q12.** Q11 の結果には、集計による NULL(小計・総計の行)と、
元データの NULL(顧客9・11 は担当が未設定)が混在します。
`GROUPING()` を使い、小計・総計の行と「担当なし」の行を **見分けられる表示** にしなさい
(例: 小計行は「(小計)」、担当なしは「(担当なし)」と出す)。

**Q13.** 「地域ごとの顧客数」と「担当ごとの顧客数」と「全顧客数(総計)」の
**3種類の集計だけ** が欲しいとします。`GROUPING SETS` を使って1つのクエリで出しなさい
(地域×担当の細かい組み合わせは不要)。

**Q14.** 次の主張は正しいですか。
「`COUNT(*)` と `COUNT(列)` はどちらも行数を数えるので、いつでも置き換えてよい」。
正誤を述べ、`Employees` の `Email` 列を例に、具体的にどう違うかを説明しなさい
(SQLは確認用に書いてよい)。
