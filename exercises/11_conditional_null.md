# 演習 11 — 条件式と NULL 処理

対象解説: [docs/11_conditional_null.md](../docs/11_conditional_null.md)
前提: [docs/10_pivot_unpivot.md](../docs/10_pivot_unpivot.md)、[docs/02_where_filtering.md](../docs/02_where_filtering.md)
使用DB: `SalesLearning`(先頭で `USE SalesLearning;` を実行しておくこと)

各問、**まず自力でクエリを書いて実行** → 結果を確認 → 解答例
[solutions/11_conditional_null.sql](solutions/11_conditional_null.sql) と照合しましょう。
解答例と書き方が違っても、同じ結果になっていれば正解です。

---

## 基礎

**Q1.** `Employees` から、姓・名・`Email` を取り出し、`Email` が未登録(NULL)の社員は
**「(未登録)」** と表示される列「メール」を作りなさい(`COALESCE` を使う)。

**Q2.** Q1 を今度は `ISNULL` で書きなさい。結果が同じになることを確認し、
`COALESCE` と `ISNULL` の違い(標準準拠・引数個数・戻り型)を1つ以上説明できるようにしなさい。

**Q3.** `Employees` から、姓・名・`Salary` と、給与区分を表す列「給与区分」を作りなさい。
区分は **80万円以上=「高」/50万円以上80万円未満=「中」/50万円未満=「低」**(検索 `CASE`)。

**Q4.** `Employees` から、`DepartmentId` を **単純 CASE** で部署名に変換した列「部署名」を作りなさい
(1=営業部, 2=開発部, 3=マーケティング部, 4=人事部, 5=経理部)。
`DepartmentId` が NULL の社員は「未配属」と表示すること。

**Q5.** `Orders` から、`OrderId`・`OrderDate`・`ShipDate` と、`ShipDate` が NULL なら
**「未出荷」**、そうでなければ **「出荷済」** となる列「出荷状況」を `IIF` で作りなさい。

**Q6.** `Products` から、商品名・`CategoryId` を取り出し、`CategoryId` が NULL の商品は
**「未分類」** と表示される列「カテゴリ表示」を作りなさい(`COALESCE` を使う。数値を文字列にする点に注意)。

---

## 応用

**Q7.** `Employees` の `Email` について、`COUNT(*)` と `COUNT(Email)` の両方を取り、
値が違う理由(集約関数は NULL を無視する)を説明しなさい。

**Q8.** `Employees` を `DepartmentId` で `GROUP BY` して人数を数えなさい。
`DepartmentId` が NULL の社員がどのグループになるかを確認し、
さらに NULL を **「未配属」** ラベルで集計する版(`COALESCE` を SELECT と GROUP BY の両方に書く)も作りなさい。

**Q9.** `Employees` を `Email` の昇順で並べたとき、NULL がどこに来るか確認しなさい。
そのうえで、**NULL を必ず最後に回す** 並べ替えに直しなさい(`CASE` の補助キーを使う)。

**Q10.** `OrderDetails` を `ProductId` ごとに集計し、
**売上合計 ÷ 数量合計**(＝数量あたり売上)を出しなさい。ただし数量合計が 0 の場合に
ゼロ除算エラーにならないよう `NULLIF` で保護すること。
(売上 = `Quantity * UnitPrice * (1 - Discount)`)

**Q11.** `Employees` から、給与区分ごとの人数を **1行に横並び**(高・中・低の3列)で集計しなさい
(`SUM(CASE WHEN … THEN 1 ELSE 0 END)` を使う。区分は Q3 と同じ)。

**Q12.** `Products` を価格帯で区分(**1万円以上=「高価格」/1000円以上1万円未満=「中価格」/
1000円未満=「低価格」**)し、区分ごとの **商品数** と **平均単価** を求めなさい(`GROUP BY` に `CASE`)。

---

## チャレンジ

**Q13.** 次のクエリは、`Email` が NULL の社員で「連絡先」列が丸ごと NULL になってしまいます。
理由を説明し、**NULL の社員は氏名だけでも残る** よう2通り(`CONCAT` と `CONCAT_WS`)に直しなさい。

```sql
SELECT LastName + N' <' + Email + N'>' AS 連絡先
FROM   dbo.Employees;
```

**Q14.** `Orders` と `OrderDetails` を結合し、**出荷済み(ShipDate が NULL でない)注文の売上合計** と、
**未出荷を含む全売上合計** を1行に並べて出しなさい(`SUM(CASE …)` を使う)。

**Q15.** 各社員(`Employees`)の受注担当を、**受注担当が居ればその担当、居なければ
顧客の営業担当(`SalesRepId`)、それも無ければ 0** の優先順で1列にまとめたい。
`Orders` を起点に `Customers` を結合し、`COALESCE(o.EmployeeId, c.SalesRepId, 0)` で
「担当者ID」を出しなさい。`COALESCE` が2引数の `ISNULL` では書きにくい理由も説明しなさい。

**Q16.** `Employees` の `DepartmentId`(1〜5)を、`CHOOSE` を使って部署名に変換しなさい。
`DepartmentId` が NULL の社員で結果がどうなるかを確認し、
`CHOOSE` が使える条件(索引が 1 始まりの連番に対応していること)を説明しなさい。
