# 演習 30 — 列ストアインデックスとバッチモード

対象解説: [docs/30_columnstore.md](../docs/30_columnstore.md)
使用DB: `SalesLearning`(先頭で `USE SalesLearning;` を実行しておくこと)

> **この演習は `sample-db/04_analytics_data.sql` を実行して `dbo.SalesFact`(1000万行)を
> 作成済みであることが前提** です。まだなら先に実行してください(環境により 1〜3 分かかります)。
> 演習開始時点で `dbo.SalesFact` に **列ストアインデックスが1つも無い** 状態が正しいスタート地点です。

各問、**まず自力でクエリを書いて実行** → 結果を確認 → 解答例
[solutions/30_columnstore.sql](solutions/30_columnstore.sql) と照合しましょう。
解答例と書き方が違っても、同じ結果になっていれば正解です。

**この章の演習は「結果が合っているか」ではなく「数字がどう変わったか」を見てはじめて正解**です。
作業を始める前に次の3つを必ず有効にしてください。

- SSMS で `Ctrl` + `M`(実際の実行プランを含める)を ON にする
- `SET STATISTICS IO ON;` を実行しておく(**列ストアでは `LOB 論理読み取り数` と
  `セグメントのスキップ数` を見る**)
- `SET STATISTICS TIME ON;` を実行しておく

計測結果は、次のような表にメモしながら進めると学習効果が高いです。

| 問 | 対象 | 論理読み取り(LOB) | CPU時間 | 実際の実行モード | セグメント読み取り/スキップ |
|---|---|---|---|---|---|
| Q2 | dbo.SalesFact(行ストア) | 71234 / 0 | 24000 ms | Row | — |
| Q5 | dbo.SalesFactCS(列ストア) | 0 / 3812 | 900 ms | Batch | 10 / 0 |

> ⚠️ **Q1 は 1000万行のコピーと CCI 構築です。合わせて 2〜6 分かかり、
> 数百 MB のディスクを使います。** 時間とディスクに余裕があることを確認してから始めてください。
>
> ⚠️ **最後に Q14 の後片付け(`DROP TABLE IF EXISTS dbo.SalesFactCS`)まで必ず実行してください。**
> 残したまま次の章に進むと、[31 パーティショニング](../docs/31_partitioning.md) の演習で
> ディスクが不足するおそれがあります。

---

## 基礎

**Q1.**(準備)`dbo.SalesFact` の 10 列すべてを `dbo.SalesFactCS` という名前でコピーし、
そこに `CCI_SalesFactCS` という名前の **クラスター化列ストアインデックス** を作りなさい。

条件が2つあります。**両方に理由があります**。あとで Q8・Q10 で効いてきます。

1. コピーするときに `SaleId` 順で並べて入れること。
2. 列ストアインデックスの構築は **`MAXDOP = 1`** で行うこと。

(ヒント: `SELECT ... INTO dbo.SalesFactCS FROM ... ORDER BY ...` →
`CREATE CLUSTERED COLUMNSTORE INDEX ... WITH (MAXDOP = 1)`。`SELECT *` は使わないこと)

**Q2.** 次の集計クエリを **行ストアの `dbo.SalesFact`** に対して実行し、
**論理読み取り数・CPU 時間・実際の実行モード** を記録しなさい。これが「Before」の基準値になります。

```sql
SELECT YEAR(SaleDate) AS 年, RegionId AS 地域,
       SUM(Amount) AS 売上合計, COUNT_BIG(*) AS 件数
FROM   dbo.SalesFact
GROUP  BY YEAR(SaleDate), RegionId
ORDER  BY 年, 地域;
```

**Q3.** Q2 とまったく同じクエリを、テーブル名だけ `dbo.SalesFactCS` に変えて実行し、
同じ3つを記録しなさい。そのうえで次に答えなさい。

1. 行ストア版と列ストア版で、**何倍の差**がついたか。
2. 列ストア版の **`論理読み取り数` がほぼ 0 なのはなぜか**。どの数字を見るべきか。

**Q4.** `dbo.SalesFact`(行ストア)と `dbo.SalesFactCS`(列ストア)の
**使用サイズ(MB)と行数** を1つの結果セットで並べて表示しなさい。
圧縮率が何分の1になったかを確認すること。
(ヒント: `sys.dm_db_partition_stats` と `sys.partitions`、`sys.indexes`)

**Q5.** `dbo.SalesFactCS` の **ロウグループの一覧**(ロウグループ番号・状態・総行数・サイズ・打ち切り理由)を
表示しなさい。次の3点を確認すること。

1. ロウグループはいくつあるか。**1000万 ÷ 1,048,576 の計算と合っているか**。
2. `state_desc` はすべて `COMPRESSED` になっているか。
3. `trim_reason_desc` は何になっているか。**満杯でないロウグループがあるとしたらどれで、なぜか**。

(ヒント: `sys.dm_db_column_store_row_group_physical_stats`。**SQL Server 2016+**)

---

## 応用

**Q6.** 集計する列を減らすと、列ストアの I/O がどう変わるかを確かめなさい。
`dbo.SalesFactCS` に対して次の2つを実行し、**`LOB 論理読み取り数`** を比較すること。

1. `SELECT SUM(Amount) FROM dbo.SalesFactCS;`(1 列だけ)
2. `SELECT TOP (100) *` で全10列を取り出す

**なぜ列ストアでは `SELECT *` が特に不利なのか**を、セグメントの構造から説明しなさい。

**Q7.** `dbo.SalesFactCS` に対して次の2つのクエリを実行し、
`SET STATISTICS IO` の出力にある **「セグメント読み取り数」と「セグメントのスキップ数」** を比較しなさい。

1. `WHERE SaleDate >= '2024-01-01' AND SaleDate < '2025-01-01'` で `Amount` を合計
2. `WHERE CustomerId = 500` で `Amount` を合計

**どちらもテーブル全体は同じ 1000万行なのに、なぜスキップ数がこれほど違うのか**を説明しなさい。

**Q8.** Q7 の答えを **メタデータで裏付け**なさい。
`sys.column_store_segments` から、`dbo.SalesFactCS` の **`SaleId` 列と `CustomerId` 列**について、
ロウグループごとの `min_data_id` / `max_data_id` を並べて表示しなさい。

そのうえで、`sample-db/04_analytics_data.sql` が
**`SaleDate` を `SaleId` に比例させて生成している理由**を、この結果に即して説明しなさい。

(ヒント: `sys.column_store_segments` を `sys.partitions` → `sys.indexes` → `sys.columns` と結合する。
`segment_id` がロウグループ番号に対応する)

**Q9.** 次のクエリは Q7 の①と同じ結果を返しますが、**セグメント除外が効きません**。
理由を説明し、**除外が効く形に書き換え**て、スキップ数が変わることを確認しなさい。

```sql
SELECT SUM(Amount) FROM dbo.SalesFactCS WHERE YEAR(SaleDate) = 2024;
```

**Q10.**(デルタストアの挙動)`dbo.SalesFactCS` に対して次の2つの INSERT を順に実行し、
**それぞれの後で** ロウグループの一覧(Q5 のクエリ)を確認しなさい。

1. `dbo.SalesFact` から **1,000 行**だけコピーして INSERT する
2. `dbo.SalesFact` から **200,000 行**を `WITH (TABLOCK)` を付けて INSERT する

そのうえで次に答えなさい。

- ①のあと、新しいロウグループの `state_desc` は何になったか。それはどこに格納されているか。
- ②のあと、新しいロウグループの `state_desc` と `trim_reason_desc` は何か。①と何が違うのか。
- **その境目は何行か**。なぜそこに線が引かれているのか。

(注意: `SaleId` が重複しないよう、コピーする際は `SaleId + 100000000` のようにずらすこと。
CCI にはキー制約がないので重複しても実行はできますが、後の確認が分かりにくくなります)

**Q11.** Q10 で発生した **`OPEN` のロウグループを、タプルムーバーを待たずに今すぐ圧縮**しなさい。
実行後にロウグループ一覧を再確認し、`state_desc` と `trim_reason_desc` がどう変わったかを記録すること。
(ヒント: `ALTER INDEX ... REORGANIZE WITH (...)`。**SQL Server 2016+**)

---

## チャレンジ

**Q12.**(バッチモードの検証)**行ストアの `dbo.SalesFact`** に対して Q2 のクエリを、
次の2通りで実行して比較しなさい。

1. `OPTION (USE HINT('DISALLOW_BATCH_MODE'))` を付けて実行(= 強制的に行モード)
2. `OPTION (USE HINT('ALLOW_BATCH_MODE'))` を付けて実行

**実際の実行モード**と **CPU 時間**を記録し、次に答えなさい。

- SQL Server 2019 (15.x) 未満、または互換性レベルが 150 未満の環境では②で何が起きるか。
- 「行ストアのバッチモードがあるなら列ストアは要らない」——この主張のどこが誤りか。
  Q3 の結果と照らして、**列ストアだけが持っている利点を3つ**挙げなさい。

(ヒント: 互換性レベルは `sys.databases` の `compatibility_level` 列で確認できる。
**この演習では互換性レベルを変更しないこと**。ヒントだけで検証する)

**Q13.**(HTAP の設計判断)`dbo.OrdersBig`(100万行・行ストア)に対して、
**業務側の点検索を邪魔せずに分析クエリだけ速くしたい**とします。

1. `Status = N'完了'`(全体の約95%)の行だけを対象にした
   **フィルター選択された非クラスター化列ストアインデックス** `NCCI_OrdersBig_Done` を、
   `OrderDate` / `CustomerId` / `Amount` の3列で作りなさい。
2. `WHERE Status = N'完了'` を含む年別集計クエリを実行し、
   このインデックスが使われていること(プランに Columnstore Index Scan が出ること)を確認しなさい。
3. `WHERE Status = N'完了'` を **書かない** 同じ集計クエリでは、なぜこのインデックスが使われないのかを説明しなさい。
4. **なぜ「完了だけ」に絞るのが設計として筋が良いのか**を、
   列ストアの更新コスト(削除ビットマップ + デルタストア)の観点から説明しなさい。

> ⚠️ `dbo.OrdersBig` が無い場合は `sample-db/03_bulk_data.sql` を実行してください。
> Q14 でこのインデックスも必ず削除します。

**Q14.**(**必須の後片付け**)この演習で作成したオブジェクトをすべて削除し、
演習前の状態に戻しなさい。

1. `dbo.SalesFactCS` を **テーブルごと** 削除する。
2. Q13 で作った `NCCI_OrdersBig_Done` を削除する。
3. 削除後、**データベースに列ストアインデックスが1つも残っていないこと**を
   システムビューで確認する。
4. `dbo.SalesFact` と `dbo.OrdersBig` が **無傷で残っていること**(行数)を確認する。

> ⚠️ `dbo.SalesFact` は絶対に削除しないこと。[31 パーティショニング](../docs/31_partitioning.md) で使います。
> (ヒント: `DROP TABLE IF EXISTS` / `DROP INDEX IF EXISTS ... ON ...` は **SQL Server 2016+**。
> 確認は `sys.indexes` の `type_desc LIKE N'%COLUMNSTORE%'`)
