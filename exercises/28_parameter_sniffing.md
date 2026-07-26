# 演習 28 — パラメータスニッフィング詳解

対象解説: [docs/28_parameter_sniffing.md](../docs/28_parameter_sniffing.md)
使用DB: `SalesLearning`(先頭で `USE SalesLearning;` を実行しておくこと)
使用テーブル: **`dbo.OrdersBig`(100万行)**。`sample-db/03_bulk_data.sql` で作成済みであること。

各問、**まず自力でクエリを書いて実行** → 結果を確認 → 解答例
[solutions/28_parameter_sniffing.sql](solutions/28_parameter_sniffing.sql) と照合しましょう。
解答例と書き方が違っても、同じことが確認できていれば正解です。

> ⚠️ **この演習の安全上の約束**
> - **`DBCC FREEPROCCACHE;`(引数なし)は絶対に実行しないこと。** インスタンス全体に影響します。
>   プランのリセットは `EXEC sys.sp_recompile N'dbo.usp_○○'` か、
>   `ALTER DATABASE SCOPED CONFIGURATION CLEAR PROCEDURE_CACHE;`(このDB限定)を使います。
> - **`DBCC DROPCLEANBUFFERS` も使いません。** 比較は **論理読み取り数**で行います。
> - データベーススコープ構成を変更した問では、**必ず既定値に戻すところまで**を解答に含めること。
> - 作成したインデックスとプロシージャは、**最後の Q13 で必ず後片付け**します。

計測は毎回この2つを有効にして行ってください。

```sql
SET STATISTICS IO   ON;
SET STATISTICS TIME ON;
-- SSMS では「実際の実行プランを含める」(Ctrl+M)も ON にする
```

---

## 基礎

**Q1.** 実験の土台を用意しなさい。

1. `dbo.OrdersBig` の `Status` の値ごとの行数と割合を求めなさい。
2. `dbo.OrdersBig (Status, OrderDate)` に非クラスタ化インデックス
   `IX_OrdersBig_Status_OrderDate` を作成しなさい。
3. パラメータ `@Status NVARCHAR(10)` と `@From DATE` を取り、
   条件 `Status = @Status AND OrderDate >= @From` に合う行の
   **件数・`Amount` の合計・`Amount` の平均**を返すプロシージャ
   `dbo.usp_StatusSummary` を作成しなさい。

(ヒント: `Amount` をインデックスに含めないことが実験の肝です。`INCLUDE` を付けないこと)

---

**Q2.** **実験A(少数側が先)** を実施し、結果を記録しなさい。

1. `sp_recompile` で `dbo.usp_StatusSummary` のプランを無効化する。
2. `@Status = N'保留'`, `@From = '2024-12-01'` で実行し、**論理読み取り数**を記録する。
   このときの実行プランの形(演算子の並び)も書き留める。
3. 続けて `@Status = N'完了'`, `@From = '2015-01-01'` で実行し、論理読み取り数を記録する。
4. 3 の実行プランで **Key Lookup の「実際の実行数」** と
   **Index Seek の「推定行数」対「実際の行数」** を確認する。

(ヒント: 論理読み取り数が数百万に跳ね上がれば成功です)

---

**Q3.** Q2 の3で遅くなったクエリについて、**キャッシュを書き換えずに**
「その値に最適なプランなら何回の論理読み取りで済むのか」を測りなさい。

(ヒント: `EXEC ... WITH RECOMPILE`。プランの形がどう変わるかも確認すること)

---

**Q4.** **実験B(大多数側が先)** を実施し、Q2 の結果と比較する表を作りなさい。

1. プランを無効化してから、今度は `@Status = N'完了'`, `@From = '2015-01-01'` を先に実行する。
2. 続けて `@Status = N'保留'`, `@From = '2024-12-01'` を実行する。
3. 「先にコンパイルされた値」×「呼び出した値」の 4 通りの論理読み取り数を表にまとめ、
   **どちらの値が先にコンパイルされたほうが安全か**を判断し、その理由を説明しなさい。

---

## 応用

**Q5.** `sys.dm_exec_query_stats` を使い、
**「同じプランなのに実行ごとのコストの開きが大きいクエリ」** を検出するクエリを書きなさい。

要件:
- 実行回数が 5 回以上のものだけを対象にする。
- `max_logical_reads / min_logical_reads`(読み取りの開き)と
  `max_worker_time / min_worker_time`(CPU の開き)を計算して表示する。
- CPU 時間はミリ秒に換算して表示する。
- 対象オブジェクト名、プラン作成時刻、実行プランも一緒に出す。
- 読み取りの開きが大きい順に並べる。

(ヒント: `worker_time` はマイクロ秒。`min_logical_reads` が 0 のときのゼロ除算に注意)

---

**Q6.** キャッシュされている `dbo.usp_StatusSummary` のプランについて、
**`ParameterCompiledValue`(コンパイル時にスニッフィングされた値)** を
実行プラン XML から取り出しなさい。`@Status` と `@From` の両方が出ること。

(ヒント: `sys.dm_exec_query_plan` + `.nodes()`。
`WITH XMLNAMESPACES (DEFAULT N'http://schemas.microsoft.com/sqlserver/2004/07/showplan')` が必須)

---

**Q7.** Q6 で取得できるのは `ParameterCompiledValue` だけで、
`ParameterRuntimeValue` は出てきません。**その理由を説明**したうえで、
**両方を並べて確認する方法**を実行して確かめなさい。

さらに、コンパイル時の値と実行時の値それぞれについて
**「本来は何行のはずか」を `COUNT(*)` で数え**、乖離の大きさを数値で示しなさい。

---

**Q8.** 対策 (a) と (b) を実装して比較しなさい。

1. `dbo.usp_StatusSummary_Recompile` … 対象の `SELECT` に `OPTION (RECOMPILE)` を付けたもの。
2. `dbo.usp_StatusSummary_OptFor` … `OPTION (OPTIMIZE FOR (@Status = N'完了', @From = '2015-01-01'))`
   を付けたもの。

それぞれ `N'保留' + '2024-12-01'` → `N'完了' + '2015-01-01'` の順で実行し、
両方の呼び出しの論理読み取り数を Q2/Q4 の表に追記しなさい。
**(b) を選ぶときに「一番よく使う値」ではなく「外したときの被害が小さい値」を
代表値にすべき理由**を、この表を根拠に説明しなさい。

---

**Q9.** 対策 (c) と (e) が **同じ挙動になる**ことを確認しなさい。

1. `WHERE Status = @Status` だけを条件にした単純なプロシージャを2つ作る。
   - `dbo.usp_StatusCount_Unknown` … `OPTION (OPTIMIZE FOR UNKNOWN)` を付ける。
   - `dbo.usp_StatusCount_LocalVar` … パラメータをローカル変数に代入し直してから使う。
2. 両方を `N'保留'` で実行し、**実行プランの推定行数**を比較する。
3. その推定行数が **なぜその値になるのか**を、`DBCC SHOW_STATISTICS ... WITH DENSITY_VECTOR`
   の結果を根拠に説明しなさい。
4. **(e) より (c) を推奨する理由**を述べなさい。

(ヒント: `Status` の異なる値は2つ。100万行のうち何行と見積もられるでしょうか)

---

## チャレンジ

**Q10.** 対策 (f) の**罠**を実験で示しなさい。

1. 1つのプロシージャの中で `IF @Status = N'保留' ... ELSE ...` と分岐する
   `dbo.usp_StatusSummary_BadBranch` を作る(両分岐の SELECT は同じ内容でよい)。
2. `N'保留'` を先に実行してから `N'完了'` を実行し、**改善しないこと**を論理読み取り数で示す。
3. 分岐先を **別プロシージャ**(`dbo.usp_StatusSummary_Few` / `dbo.usp_StatusSummary_Many`)に
   切り出したルータープロシージャ `dbo.usp_StatusSummary_Router` を作り、
   **今度は改善すること**を示す。
4. なぜ 2 では効かず 3 では効くのかを説明しなさい。

---

**Q11.** 対策 (g) を **安全に** 実装しなさい。

`dbo.usp_StatusSummary_Dynamic` を作り、
**`@Status` だけをリテラルとして埋め込み、`@From` はパラメータのまま**渡す動的SQLにすること。

要件:
- 埋め込む前に **ホワイトリスト検証**(`N'完了'` / `N'保留'` 以外は `THROW`)を行う。
- リテラル化には `QUOTENAME(@Status, N'''')` を使う。
- 生成した SQL を `PRINT` で目視確認できるようにする。
- 両方の値で実行したあと、`sys.dm_exec_cached_plans` /
  `sys.dm_exec_query_stats` を使って **値ごとに別のプランがキャッシュされていること**を確認する。

最後に、この方式を **`CustomerId`(1〜12)や `OrderId`(100万通り)に適用してはいけない理由**を
述べなさい。

---

**Q12.** データベーススコープ構成でスニッフィングを止める実験をしなさい。

1. 現在の `PARAMETER_SNIFFING` の設定値を確認する。
2. `OFF` に変更し、`dbo.usp_StatusSummary` のプランを無効化してから
   `N'保留' + '2024-12-01'` で実行する。
3. Q6 のクエリで `ParameterCompiledValue` を取得し、**どうなっているか**を確認する。
4. **必ず `ON` に戻し**、戻ったことを `sys.database_scoped_configurations` で確認する。
5. この設定を本番で使うべきでない理由を、解説の第1節を踏まえて述べなさい。

---

**Q13.** メモリ付与量のスニッフィングを観測し、**最後に後片付け**をしなさい。

1. 解説第13節の `dbo.usp_StatusRanking` を作成する。
2. `N'保留'` → `N'完了'` の順で実行し、
   `SET STATISTICS IO` の出力に **`テーブル 'Worktable'`** が現れること
   (= ソートが tempdb にこぼれたこと)を確認する。
   実際の実行プランの Sort 演算子に警告マークが付いていることも確認する。
3. 逆順(`N'完了'` → `N'保留'`)にした場合、
   何が問題になるかを述べ、それを確認するための DMV を挙げなさい。
4. **後片付け**: この演習で作成した全プロシージャとインデックス
   `IX_OrdersBig_Status_OrderDate` を削除し、
   `dbo.OrdersBig` に `PK_OrdersBig` だけが残っていることを確認しなさい。
   データベーススコープ構成が既定値に戻っていることも併せて確認すること。

---

**Q14.**(記述問題)次のフローに沿って、実務での判断を説明しなさい。

ある本番システムで「毎朝 9 時台だけ、顧客検索プロシージャが 30 秒かかる」という
報告が上がりました。日中は 0.2 秒で終わります。夜間に統計情報の自動更新ジョブが走っています。

1. **最初に確認する DMV / ビュー**を3つ挙げ、それぞれ **何を見て何を判断するか**を述べなさい。
2. スニッフィングだと確定させるために **決定的な証拠**として何を提示すべきか述べなさい。
3. このプロシージャが **1日に約 200 回**しか呼ばれないと分かった場合、
   解説の (a)〜(i) のどれを第一候補にするか、**副作用を明示したうえで**選びなさい。
4. アプリケーションのコードを **一切変更できない**という制約が判明した場合、
   選択肢はどう変わるか述べなさい。
