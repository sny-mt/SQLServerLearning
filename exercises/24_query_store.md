# 演習 24 — Query Store

対象解説: [docs/24_query_store.md](../docs/24_query_store.md)
使用DB: `SalesLearning`(先頭で `USE SalesLearning;` を実行しておくこと)

> ⚠️ **Query Store は SQL Server 2016 以降の機能**です。2014 以前ではこの演習は実施できません。
> `sys.query_store_wait_stats` を使う Q12 は **2017 以降**が必要です。

> **この演習は `sample-db/03_bulk_data.sql` を実行して `dbo.OrdersBig`(100万行)を
> 作成済みであることが前提** です。まだなら先に実行してください。
> また、`dbo.OrdersBig` に **非クラスタ化インデックスが1本もない**状態がスタート地点です
> ([18 の演習](18_indexes_execution_plans.md)の後片付けを済ませておくこと)。

各問、**まず自力でクエリを書いて実行** → 結果を確認 → 解答例
[solutions/24_query_store.sql](solutions/24_query_store.sql) と照合しましょう。
解答例と書き方が違っても、同じ結果になっていれば正解です。

---

## ⚠️ この演習の安全上の約束(必ず先に読むこと)

この演習は **データベースの設定を変更します**(`ALTER DATABASE ... SET QUERY_STORE`)。
次の3点を必ず守ってください。

1. **Q1 で「変更前の状態」を必ず記録してから始める。**
   `sys.database_query_store_options` の出力を、コピーしてメモ帳などに貼り付けておくこと。
2. **Q14 の後片付け(強制解除 → `CLEAR` → 元の状態へ戻す)まで必ず実行する。**
3. **本番環境・共用の検証環境では絶対に実行しない。** 手元の学習用インスタンスだけで行うこと。

> 💡 この演習では観察しやすさのために `INTERVAL_LENGTH_MINUTES = 1`、
> `DATA_FLUSH_INTERVAL_SECONDS = 60` という**本番では使わない設定**を使います。
> 理由を Q2 で説明できるようにしてください。

計測結果は、次のような表にメモしながら進めると学習効果が高いです。

| 問 | query_id | plan_id | 実行回数 | 平均経過ms | 平均論理読み取り |
|---|---|---|---|---|---|
| Q9 | … | … | … | … | … |

---

## 基礎

**Q1.**(**必ず最初に実行すること**)
`SalesLearning` の Query Store の現在の設定を `sys.database_query_store_options` から取得しなさい。
少なくとも次の列を含めること。

- 設定上の状態(`desired_state_desc`)/ 実際の状態(`actual_state_desc`)
- 読み取り専用理由(`readonly_reason`)
- 現在サイズ・上限サイズ・集計間隔・フラッシュ間隔・収集モード・保持日数

**この結果は Q14 で元に戻すときに使うので、必ず控えておくこと。**

**Q2.** `SalesLearning` の Query Store を、次の設定で有効化しなさい。

| オプション | 値 |
|---|---|
| `OPERATION_MODE` | `READ_WRITE` |
| `DATA_FLUSH_INTERVAL_SECONDS` | `60` |
| `INTERVAL_LENGTH_MINUTES` | `1` |
| `MAX_STORAGE_SIZE_MB` | `1024` |
| `QUERY_CAPTURE_MODE` | `ALL` |
| `SIZE_BASED_CLEANUP_MODE` | `AUTO` |
| `STALE_QUERY_THRESHOLD_DAYS` | `7` |

設定後、Q1 と同じクエリで反映を確認しなさい。
そのうえで、**この3つの設定が「学習用であって本番向きではない」理由**をそれぞれ説明しなさい。

1. `INTERVAL_LENGTH_MINUTES = 1`
2. `DATA_FLUSH_INTERVAL_SECONDS = 60`
3. `QUERY_CAPTURE_MODE = ALL`

**Q3.** これまでに記録された内容をすべてクリアし、まっさらな状態から観察を始めなさい。
クリア後、`sys.query_store_query` の行数が 0 件になっていることを確認すること。
また、**`CLEAR` が本番環境で危険な理由**を一言で述べなさい。

**Q4.**(**負荷を流す**)次の2種類のクエリを `dbo.OrdersBig` に対して流し、Query Store に記録させなさい。

- **速いクエリ**: `OrderId`(クラスタ化主キー)で1行だけ取り出す。**20回**繰り返す。
- **遅いクエリ**: 2023年の注文件数を `YEAR(OrderDate) = 2023` という**非SARGableな条件**で数える。**10回**繰り返す。
- **中くらいのクエリ**: 2023年6月の注文件数を、`>=` と `<` の範囲条件で数える。**10回**繰り返す。

流し終えたら、**メモリ上のデータをディスクへ強制的に書き出し**、
`sys.query_store_query` / `sys.query_store_plan` / `sys.query_store_runtime_stats` の
それぞれの行数を確認しなさい。

> ヒント: SSMS では `GO 20` と書くと直前のバッチを20回繰り返せます。
> フラッシュには `sys.sp_query_store_flush_db` を使います。

---

## 応用

**Q5.** Query Store に記録されたクエリのうち、**合計CPU時間が多い順に上位10件**を出しなさい。
出力には次を含めること。

- `query_id`、クエリテキスト、**プラン数**、実行回数
- 合計CPU時間(**ミリ秒**)、実行1回あたりの平均CPU時間(ミリ秒)、平均経過時間(ミリ秒)
- 最終実行時刻

(ヒント: `sys.query_store_query` / `_query_text` / `_plan` / `_runtime_stats` を結合する。
時間の単位は**マイクロ秒**なので変換が必要)

**Q6.** 同様に、**合計論理読み取りページ数が多い順に上位10件**を出しなさい。
平均論理読み取りページ数と **平均返却行数(`avg_rowcount`)** も並べて出力すること。
結果を見て、「**返却行数のわりに読み取りページ数が異常に多いクエリ**」がどれか答え、
その原因を [18 章](../docs/18_indexes_execution_plans.md) の知識で説明しなさい。

**Q7.** **実行回数が多い順に上位10件**を出しなさい。
`sys.query_store_query` の `count_compiles`(コンパイル回数)も並べて出力し、
**実行回数とコンパイル回数がほぼ同じクエリがあれば何を意味するか**を述べなさい。

**Q8.** 次の2つのクエリは、どちらも「クエリごとの平均経過時間」を求めようとしています。
**一方は誤りです。どちらが誤りで、なぜ誤りなのか**を説明しなさい。
実際に両方を実行して、値が食い違うことを確認すること。

```sql
-- A
SELECT q.query_id, AVG(rs.avg_duration) / 1000.0 AS 平均ミリ秒 ...

-- B
SELECT q.query_id,
       SUM(rs.avg_duration * rs.count_executions)
           / SUM(rs.count_executions) / 1000.0 AS 平均ミリ秒 ...
```

**Q9.**(**プランリグレッションを人工的に起こす**)次の手順を実行しなさい。

1. `dbo.OrdersBig` の `OrderDate` 列に `IX_OrdersBig_OrderDate` という非クラスタ化インデックスを作る。
2. 2023年6月の注文件数を数えるクエリ(Q4 の「中くらいのクエリ」と**まったく同じテキスト**)を **20回**流す。
3. `IX_OrdersBig_OrderDate` を**削除する**。
4. **手順2とまったく同じクエリ**をもう一度 **20回**流す。
5. フラッシュする。

そのうえで、**同一クエリに複数のプランが記録されていること**を確認し、
**プランごとの平均経過時間・平均CPU時間・平均論理読み取りページ数・初回実行・最終実行**を
比較する一覧を出しなさい。

**どちらのプランが劣化したプランか**、そして
**「サーバーが混んでいて遅かっただけ」ではなく本当にプランが悪化したと断定できる根拠**を述べなさい。

> ヒント: 手順2と4のクエリテキストは1文字も変えないこと(変えると別の `query_id` になります)。

---

## チャレンジ

**Q10.** Q9 で見つけたリグレッションについて、**良かったほうのプランを強制**しなさい。
強制後に、`is_forced_plan` / `plan_forcing_type_desc` / `force_failure_count` /
`last_force_failure_reason_desc` を出力して、正しく強制されていることを確認すること。
さらに、**同じクエリをもう一度実行して、強制したプランで動いていること**を確かめなさい。

(ヒント: `sys.sp_query_store_force_plan @query_id = , @plan_id = `)

**Q11.**(**強制を失敗させて学ぶ**)
Q10 で強制したプランが **Index Seek を使うプラン**だった場合、
そのプランが依存する `IX_OrdersBig_OrderDate` を削除すると強制はどうなるでしょうか。

1. 必要なら `IX_OrdersBig_OrderDate` を作り直し、Seek プランを強制し直す。
2. インデックスを削除する。
3. 同じクエリを数回実行する。
4. `force_failure_count` と `last_force_failure_reason_desc` を確認する。

**どんな失敗理由が記録されたか**を答え、
**「プランを強制したあとにインデックスを削除してはいけない」理由**を説明しなさい。
最後に、**強制を解除**すること。

**Q12.**(**2017+**)`sys.query_store_wait_stats` を使って、
**待機時間の合計が多いクエリ 上位10件**を、待機カテゴリ別に出しなさい。
出力には合計待機ミリ秒・実行1回あたり待機ミリ秒・最大待機ミリ秒を含めること。

さらに、[23 待機統計とボトルネック特定](../docs/23_wait_statistics.md) の
`sys.dm_os_wait_stats` と比べて、**Query Store の待機統計にしかできないこと**と
**Query Store の待機統計では分からないこと**をそれぞれ1つ以上挙げなさい。

> ヒント: 待機時間の単位は **ミリ秒**です(実行時統計のマイクロ秒とは違います)。
> `sys.query_store_runtime_stats` と結合するときは、`plan_id` だけでなく
> `runtime_stats_interval_id` と `execution_type` も結合条件に含めること。

**Q13.**(**記述問題**)
あなたは本番環境で、あるクエリが「先週まで平均 30ms だったのに、今週は平均 4,200ms」に
なっていることを Query Store で発見しました。プランIDも変わっています。

**プランを強制する前に確認すべきこと**を、優先順位をつけて3つ以上挙げ、
それぞれ**何をどう調べるか(DMV名・コマンド名レベルで)**具体的に書きなさい。
また、**プランを強制することの長期的なリスク**を2つ以上述べなさい。

**Q14.**(**必須の後片付け**)次をすべて実行して、演習前の状態に戻しなさい。

1. **強制されているプランをすべて解除**する(1つも残っていないことを確認)。
2. この演習で作成した `IX_OrdersBig_OrderDate` が残っていれば削除する。
3. Query Store の記録内容を **`CLEAR`** する。
4. **Q1 で記録した元の状態に戻す**(元が `OFF` だったなら `OFF` にする)。
5. `sys.database_query_store_options` で戻ったことを確認する。

> ⚠️ **`CLEAR` してから `OFF`** の順で実行すること。逆にすると記録データがDB内に残り続けます。
