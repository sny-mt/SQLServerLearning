# 演習 29 — 結合アルゴリズムと並列処理

対象解説: [docs/29_join_algorithms_parallelism.md](../docs/29_join_algorithms_parallelism.md)
使用DB: `SalesLearning`(先頭で `USE SalesLearning;` を実行しておくこと)

> **この演習は `sample-db/03_bulk_data.sql` を実行して `dbo.OrdersBig`(100万行)を
> 作成済みであることが前提** です。まだなら先に実行してください。
> 演習開始時点で `dbo.OrdersBig` には **非クラスタ化インデックスが1本もない** 状態が
> 正しいスタート地点です([18 の後片付け](../docs/18_indexes_execution_plans.md) が済んでいるか確認)。

各問、**まず自力でクエリを書いて実行** → 結果を確認 → 解答例
[solutions/29_join_algorithms_parallelism.sql](solutions/29_join_algorithms_parallelism.sql) と照合しましょう。
解答例と書き方が違っても、同じ結果になっていれば正解です。

**この章の演習は「結果が合っているか」ではなく
「どの物理演算子が選ばれ、メモリをいくら要求し、並列になったか」を読み取れて
はじめて正解**です。作業前に必ず次を有効にしてください。

- SSMS で `Ctrl` + `M`(**実際の**実行プランを含める)を ON にする
  ※ **推定プラン(`Ctrl`+`L`)ではスピル警告もスレッド別行数も見えません**
- クエリの前で `SET STATISTICS IO ON;` と `SET STATISTICS TIME ON;` を実行しておく

計測結果は次のような表にメモしながら進めると学習効果が高いです。

| 問 | 物理演算子 | 論理読み取り数 | 要求メモリKB | CPU時間 / 経過時間 | スピル |
|---|---|---|---|---|---|
| Q1 | Nested Loops | … | … | … | なし |

> ⚠️ **注意事項(必ず読むこと)**
> - **Q17 の後片付けまで必ず実行してください。** インデックスや設定を残したまま
>   次の章に進むと、以降の計測がすべて狂います。
> - **`sp_configure` を使う問題(Q15)は、自分専用のローカル環境でのみ**行ってください。
>   共有サーバーでは Q15 を飛ばして構いません(読んで理解するだけでよい)。
> - 数値はすべて **環境により前後する目安** です。大事なのは **絶対値ではなく変化の桁** です。

---

## 基礎

**Q1.** `dbo.OrdersBig` と `dbo.Customers` を `CustomerId` で内部結合し、
`OrderId` が 1〜100 の注文について `OrderId` / `OrderDate` / `CustomerName` を取り出しなさい。
プランに現れた **物理結合演算子の名前** と **論理読み取り数** を記録し、
**なぜその演算子が選ばれたのか** を「外側の行数」という言葉を使って説明しなさい。

**Q2.** Q1 から `WHERE` を外し、代わりに顧客ごとの注文件数を集計しなさい
(`CustomerName` と件数)。物理結合演算子が Q1 から **どう変わったか** を記録し、
**同じ `INNER JOIN` なのに変わった理由** を説明しなさい。

**Q3.** `dbo.Employees` と `dbo.OrdersBig` を `EmployeeId` で内部結合し、
社員の姓(`LastName`)ごとの注文件数を求めなさい。次の2通りで実行して比較すること。

1. オプティマイザに任せる
2. `OPTION (LOOP JOIN, FORCE ORDER, MAXDOP 1)` で Nested Loops を強制する

**2の `OrdersBig` の論理読み取り数とスキャン カウント**を記録し、
1 との差が **何倍** になったか、**なぜそうなるのか** を説明しなさい。
(ヒント: `dbo.OrdersBig` の `EmployeeId` にはインデックスがない)

**Q4.** `dbo.OrdersBig` の `CustomerId` 列に `IX_OrdersBig_CustomerId` という名前で
非クラスタ化インデックスを作りなさい。そのうえで Q2 と同じ集計を
`OPTION (MERGE JOIN, MAXDOP 1)` で実行し、**プランに `Sort` が現れないこと** を確認しなさい。
**なぜソートが不要なのか** を、両側の入力の並び順から説明すること。

---

## 応用

**Q5.** Q4 と同じ集計を、今度は `EmployeeId` での結合に変えて
`OPTION (MERGE JOIN, MAXDOP 1)` を付けて実行しなさい。
プランに **`Sort` が現れること** を確認し、その `Sort` が
**何行を並べ替えているか**(実際の行数)を記録しなさい。
さらに、Q4 と Q5 の違いから **「Merge Join が効率的」と言えるのはどういう場合か** を1文でまとめなさい。

**Q6.** Q2 の集計を、次の2通りの `OPTION` で実行し、
**いちばん左の `SELECT` 演算子のプロパティ `MemoryGrantInfo`** を開いて
`RequestedMemory` と `MaxUsedMemory` を記録・比較しなさい。

1. `OPTION (HASH JOIN, MAXDOP 1)`
2. `OPTION (HASH JOIN, FORCE ORDER, MAXDOP 1)`(`FROM` は `dbo.OrdersBig` を先に書くこと)

**同じ結果を返す同じ結合なのに要求メモリが大きく変わる理由** を、
build 側 / probe 側という言葉を使って説明しなさい。

**Q7.** `dbo.OrdersBig` の `OrderId` と `Amount` の組み合わせの重複を除いた件数
(= 100万件)を求めるクエリを書き、次の2通りで実行しなさい。

1. `OPTION (HASH GROUP, MAXDOP 1)`
2. `OPTION (HASH GROUP, MAXDOP 1, MAX_GRANT_PERCENT = 1)`

2 で **スピルが起きていること** を、次の **3つの経路すべて** で確認しなさい。

- 実行プランの警告アイコンとそのプロパティ(何という名前の警告か)
- `SET STATISTICS IO` の出力に現れる **あるもの**
- 経過時間の変化

**Q8.** 直前に実行したクエリのスピル状況を、`sys.dm_exec_query_stats` から取得するクエリを書きなさい。
`total_spills` に加えて **`last_grant_kb` と `last_used_grant_kb` も取得** し、
**この2列を並べて見ると何が分かるのか** を説明しなさい。
(ヒント: スピル関連の列は **SQL Server 2016 SP2 / 2017 CU3 以降**)

**Q9.** 実行中のクエリのメモリ許可を観測する `sys.dm_exec_query_memory_grants` のクエリを書きなさい。
最低限、要求 / 許可 / 最低必要 / 最大使用 の各メモリ量、`dop`、`grant_time`、`wait_time_ms` を含めること。
そのうえで、次の3つの状況で **それぞれどの列がどうなっているか** を答えなさい。

1. メモリ許可を待たされている
2. 過大推定でメモリを無駄に占有している
3. 要求が削られてスピルしそう

**Q10.** 次の集計クエリを、`OPTION (MAXDOP 1)` あり / なしの2通りで実行しなさい。

```sql
SELECT e.LastName, c.Region, COUNT(*) AS 件数, SUM(o.Amount) AS 金額
FROM   dbo.OrdersBig AS o
INNER JOIN dbo.Customers AS c ON c.CustomerId = o.CustomerId
INNER JOIN dbo.Employees AS e ON e.EmployeeId = o.EmployeeId
GROUP  BY e.LastName, c.Region;
```

**`SET STATISTICS TIME` の CPU 時間と経過時間の関係だけを見て、
どちらが並列実行されたかを判定**しなさい。判定の根拠も述べること。
また、**論理読み取り数が並列化でほとんど変わらないのはなぜか** を説明しなさい。

---

## チャレンジ

**Q11.** Q10 の並列プランに現れる **`Parallelism` (Exchange) 演算子をすべて見つけ**、
それぞれについて次を記録しなさい。

- プロパティの **`Logical Operation`**(Distribute / Repartition / Gather のどれか)
- プロパティの **`Partitioning Type`**(Hash / Round Robin / Broadcast / Range / Demand のどれか)

そのうえで **`Gather Streams` がプランのどのあたりに、いくつ現れるか** と、
**その理由** を説明しなさい。

**Q12.** サーバーの並列関連の待機統計(`CX` で始まる待機タイプ)を一覧するクエリを書きなさい。
そのうえで次を説明しなさい。

1. **`CXCONSUMER` と `CXPACKET` の違い**、および **どのバージョンで分離されたか**
2. なぜ分離が必要だったのか(分離前に世の中でどんな誤った対処が広まったか)
3. `CXPACKET` が上位に出たときに **最初に確認すべきこと**

**Q13.** Q10 の並列プランで、**スレッド間の行数の偏り (skew)** を確認する手順を実際に行い、
文章で説明しなさい。最低限、次の3点を含めること。

- どの演算子の、**どのプロパティを展開**するのか
- **`Thread 0`** をどう扱うべきか、それはなぜか
- 「偏っている」と判断する目安

さらに、**実行中**のクエリについて同じことを調べるための DMV を使ったクエリも書きなさい。

**Q14.** データベース スコープ構成で `MAXDOP` を 1 に変更し、Q10 のクエリが直列になることを確認し、
**必ず元に戻し**なさい。次の5ステップをすべて含む1つのスクリプトとして書くこと。

1. 変更前の値を記録する(確認クエリ)
2. 変更する
3. 効果を確認する
4. **元に戻す**
5. 戻ったことを確認する

**この設定粒度は、クエリヒント `OPTION (MAXDOP n)` と比べて何が違うのか**、
また **検証時にどちらを優先して使うべきか** も述べなさい。

**Q15.**(**ローカル環境限定。共有サーバーでは実行しないこと**)
`cost threshold for parallelism` の現在値を確認し、50 に変更してから
**必ず元の値に戻す**スクリプトを、Q14 と同じ5ステップ構成で書きなさい。
そのうえで、**MAXDOP の4つの設定粒度を優先順位の高い順に並べ**、
**並列を抑止したいときに影響範囲の狭い順に試すべき順序** を示しなさい。

**Q16.** 次のクエリには2つの問題があります。**両方を指摘**し、修正案を示しなさい。

```sql
-- 顧客ごとの注文件数(前任者がチューニングしたもの)
SELECT c.CustomerName, COUNT(*) AS 件数
FROM   dbo.OrdersBig AS o
INNER LOOP JOIN dbo.Customers AS c ON c.CustomerId = o.CustomerId
GROUP  BY c.CustomerName;
```

1. **結合レベルの結合ヒント**を書いたことによる、意図していない副作用は何か
2. このヒントを残したまま `dbo.Customers` が将来 500万行に増えたら何が起きるか

そのうえで、**結合ヒントに手を伸ばす前に試すべきこと** を、
関連する章の番号とともに **順番に** 列挙しなさい。

**Q17.**(**必須の後片付け**)この演習で作成したインデックスをすべて削除し、
`dbo.OrdersBig` を演習前の状態(`PK_OrdersBig` だけがある状態)に戻しなさい。
あわせて、**データベース スコープ構成とサーバー設定が元の値に戻っていること** を
確認するクエリも実行しなさい。

---

### 発展課題(任意・解答例なし)

- `dbo.OrdersBig` を自己結合して **多対多の Merge Join** を発生させ、
  `SET STATISTICS IO` に **ワークテーブル** が現れることを確認しなさい。
  ただし `CustomerId` は12種類しかないため、**必ず `TOP` で入力を絞る**こと
  (絞らないと組み合わせ爆発で終わりません)。
- [30 列ストアインデックスとバッチモード](../docs/30_columnstore.md) を終えたあとに戻ってきて、
  `dbo.SalesFact` に列ストアを作り、**`Adaptive Join`** 演算子と
  そのプロパティ `Adaptive Threshold Rows` / `Actual Join Type` を観察しなさい。
- 拡張イベント([25 拡張イベント](../docs/25_extended_events.md))でセッションを作り、
  `sort_warning` / `hash_warning` / `exchange_spill` を捕捉して、
  Q7 のスピルがイベントとして記録されることを確認しなさい。
