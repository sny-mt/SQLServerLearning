# 演習 12 — 組み込み関数(文字列・日付・数値・変換)

対象解説: [docs/12_builtin_functions.md](../docs/12_builtin_functions.md)
使用DB: `SalesLearning`(先頭で `USE SalesLearning;` を実行しておくこと)

各問、**まず自力でクエリを書いて実行** → 結果を確認 → 解答例
[solutions/12_builtin_functions.sql](solutions/12_builtin_functions.sql) と照合しましょう。
解答例と書き方が違っても、同じ結果になっていれば正解です。

明細金額は `Quantity * UnitPrice * (1 - Discount)` で計算します。
バージョン依存機能を使う問題には (2016+) / (2017+) と明記しています。

---

## 基礎

**Q1.** `Employees` から、姓と名を半角スペースで連結した「氏名」列を作りなさい。
`Email` が NULL の社員でも氏名が欠けないよう、**`CONCAT` を使う**こと。

**Q2.** `Products` から、商品名(`ProductName`)・その **文字数**・その **バイト長** の
3 列を出しなさい。日本語列で `LEN` と `DATALENGTH` の値がどう違うかを確認すること。

**Q3.** `Products` から、商品名の **先頭 3 文字** と **末尾 2 文字** を取り出しなさい
(`LEFT` / `RIGHT`)。

**Q4.** `Products` の `ProductName` に含まれる「ノート」を「NOTE」に置換した列を出しなさい
(`REPLACE`)。

**Q5.** `Orders` から、`OrderDate` の **年・月・日** をそれぞれ数値列として取り出しなさい。

**Q6.** `Products` の `UnitPrice` を、**カンマ区切り(小数 0 桁)** の文字列に整形しなさい。
(ヒント: `FORMAT(..., 'N0')`。表示専用の整形であることを意識)

---

## 応用

**Q7.** `Employees` の `Email` から **@ より後ろのドメイン部分** を取り出しなさい
(`CHARINDEX` + `SUBSTRING`)。`Email` が NULL の社員は結果に含めないこと。

**Q8.** `Orders` から、注文ごとの **出荷までの日数**(`OrderDate` から `ShipDate` まで)を
`DATEDIFF` で出しなさい。**未出荷(`ShipDate` が NULL)** の注文が結果でどう表示されるかも
確認すること。

**Q9.** `Employees` から、各社員の **勤続年数(満年数)** を求めなさい。
`DATEDIFF(YEAR, ...)` の単純計算では応当日前に 1 多くなることを踏まえ、
**入社応当日をまだ迎えていない場合は 1 を引く** 補正を入れること。

**Q10.** `Orders` から、`OrderDate` の **月初** と **月末** を出しなさい
(月末は `EOMONTH`(2016+)、月初は `DATEFROMPARTS` などで日=1 を作る)。

**Q11.** `OrderDetails` から、明細ごとの明細金額 `Quantity * UnitPrice * (1 - Discount)` を
**整数に四捨五入** した列を出しなさい(`ROUND`)。

**Q12.** `Orders` の `OrderDate` を、`CONVERT` のスタイルを使って
**`yyyy/mm/dd` 形式の文字列**(例: `2023/01/15`)に整形しなさい。

---

## チャレンジ

**Q13.** (2017+) 顧客ごとに、**購入した商品名をカンマ区切りで 1 つの文字列にまとめた一覧** を
作りなさい(`STRING_AGG`)。`Customers` → `Orders` → `OrderDetails` → `Products` を結合し、
顧客名でグループ化すること。商品名は昇順に並べられるとなおよい。

**Q14.** 次の 2 つの文字列を **整数に変換** しようとしています。
`'480000'` と `'480,000'`(カンマ入り)。`TRY_CAST(... AS INT)` を両方に適用し、
**片方が NULL になる理由** をコメントで説明しなさい。カンマ入りの方も整数化するには
どう前処理すればよいか(ヒント: `REPLACE` でカンマを除去)も示すこと。

**Q15.** `Employees` から社員ごとに、
`「氏名(姓 名) / 入社: yyyy-mm-dd / 勤続 N 年 / ドメイン: xxx」`
という **1 行の説明文字列** を組み立てなさい。
`Email` が NULL の社員はドメイン部分を `N'(なし)'` と表示すること
(ヒント: `CONCAT`、勤続年数は Q9 の式、ドメインは Q7 の式、NULL 対策に `ISNULL`/`CASE`)。
