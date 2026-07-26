# 演習 18 — インデックスと実行プラン

対象解説: [docs/18_indexes_execution_plans.md](../docs/18_indexes_execution_plans.md)
使用DB: `SalesLearning`(先頭で `USE SalesLearning;` を実行しておくこと)

> **この演習は `sample-db/03_bulk_data.sql` を実行して `dbo.OrdersBig`(100万行)を
> 作成済みであることが前提** です。まだなら先に実行してください。
> 演習開始時点で `dbo.OrdersBig` には **非クラスタ化インデックスが1本もない** 状態が正しいスタート地点です。

各問、**まず自力でクエリを書いて実行** → 結果を確認 → 解答例
[solutions/18_indexes_execution_plans.sql](solutions/18_indexes_execution_plans.sql) と照合しましょう。
解答例と書き方が違っても、同じ結果になっていれば正解です。

**この章の演習は「結果が合っているか」だけでなく「プランと論理読み取り数がどう変わったか」まで見て
はじめて正解**です。作業を始める前に次の2つを必ず有効にしてください。

- SSMS で `Ctrl` + `M`(実際の実行プランを含める)を ON にする
- クエリの前で `SET STATISTICS IO ON;` を実行しておく

計測結果は、次のような表にメモしながら進めると学習効果が高いです。

| 問 | クエリ | 演算子(Seek/Scan) | 論理読み取り数 |
|---|---|---|---|
| Q1 | … | Clustered Index Scan | 6018 |

> ⚠️ **最後に Q13 の後片付け(DROP INDEX)まで必ず実行してください。**
> インデックスを残したまま次の章に進むと、他の演習の計測結果が変わってしまいます。

---

## 基礎

**Q1.** `dbo.OrdersBig` から `OrderDate` が `2023-06-01` の注文件数を数えなさい。
このとき **実行プランの演算子名** と **論理読み取り数** を記録すること。
(まだインデックスは作らない。ここが「Before」の基準値になる)

**Q2.** `dbo.OrdersBig` から `OrderId = 500000` の1行を `SELECT *` で取り出しなさい。
Q1 と同じく演算子名と論理読み取り数を記録し、**Q1 との差がなぜ生まれるのか** を説明しなさい。
(ヒント: `OrderId` はクラスタ化主キー)

**Q3.** `OrderDate` 列に `IX_OrdersBig_OrderDate` という名前の非クラスタ化インデックスを作りなさい。
作成後に Q1 とまったく同じクエリを再実行し、**演算子名と論理読み取り数がどう変わったか** を記録しなさい。

**Q4.** 現在 `dbo.OrdersBig` に存在するインデックスの一覧(名前と種別)を、
システムビューから取得しなさい。
(ヒント: `sys.indexes` と `OBJECT_ID('dbo.OrdersBig')`)

---

## 応用

**Q5.** 次のクエリは 2023 年の注文件数を返しますが、`IX_OrdersBig_OrderDate` があるのに
Index Seek になりません。**理由を説明**し、**同じ結果のまま Index Seek になるように書き換え**なさい。
書き換え前後の論理読み取り数を比較すること。

```sql
SELECT COUNT(*) FROM dbo.OrdersBig WHERE YEAR(OrderDate) = 2023;
```

**Q6.** 次の3つのクエリはいずれも SARGable ではありません。
それぞれ **同じ結果を返す SARGable な形に書き換え**なさい。

1. `WHERE Amount * 2 > 1000`
2. `WHERE CONVERT(VARCHAR(8), OrderDate, 112) = '20230601'`
3. `WHERE ISNULL(ShipDate, '9999-12-31') > '2024-12-01'`

**Q7.** `OrderDate = '2023-06-01'` の注文について、`OrderId`・`OrderDate`・`Amount` の3列を取り出しなさい。
プランに **Key Lookup** が現れることを確認し、論理読み取り数を記録しなさい。
**なぜ Key Lookup が必要になるのか** を、非クラスタ化インデックスの構造から説明すること。

**Q8.** Q7 のクエリを **1文字も変えずに** Key Lookup を消しなさい。
(ヒント: `IX_OrdersBig_OrderDate` を作り直して `INCLUDE` を使う)
消した後の論理読み取り数を Q7 と比較しなさい。

**Q9.** `Status` 列に `IX_OrdersBig_Status` という非クラスタ化インデックスを作りなさい。
そのうえで次の2つを実行し、**同じ形なのにプランが違う理由** を説明しなさい。

1. `WHERE Status = N'保留'` の件数
2. `WHERE Status = N'完了'` の件数

---

## チャレンジ

**Q10.** `(Status, OrderDate)` の順の複合インデックス `IX_OrdersBig_Status_OrderDate` を作りなさい。
そのうえで次の3つのクエリを実行し、**どれが Seek でき、どれができないか** を確認して理由を説明しなさい。

1. `WHERE Status = N'保留' AND OrderDate >= '2023-01-01' AND OrderDate < '2024-01-01'`
2. `WHERE Status = N'保留'`
3. `WHERE OrderDate >= '2023-01-01' AND OrderDate < '2024-01-01'`

さらに、「`(OrderDate, Status)` の順にしていたら 3 はどうなっていたか」も考えなさい。

**Q11.** 次のクエリを **実際の実行プラン(`Ctrl`+`M`)** で実行し、
Index Seek 演算子の **推定行数と実際の行数** を比較しなさい。
乖離が起きる理由を説明し、乖離を解消する書き方を1つ示しなさい。

```sql
DECLARE @d DATE = '2024-12-01';
SELECT COUNT(*) FROM dbo.OrdersBig WHERE OrderDate >= @d;
```

**Q12.** `dbo.OrdersBig` の各インデックスについて、
**使用サイズ(KB)** と **シーク回数・スキャン回数・更新回数** を一覧するクエリを書きなさい。
その結果から「**このテーブルに実運用でインデックスを残すとしたらどれか、なぜか**」を
インデックスのコスト(更新負荷・容量)の観点から述べなさい。
(ヒント: `sys.dm_db_partition_stats` と `sys.dm_db_index_usage_stats`)

**Q13.**(**必須の後片付け**)この演習で作成したすべての非クラスタ化インデックスを削除し、
`dbo.OrdersBig` を演習前の状態(`PK_OrdersBig` だけがある状態)に戻しなさい。
削除後、インデックスが本当に残っていないことをシステムビューで確認すること。
(ヒント: `DROP INDEX IF EXISTS ... ON dbo.OrdersBig;` は **SQL Server 2016+**)
