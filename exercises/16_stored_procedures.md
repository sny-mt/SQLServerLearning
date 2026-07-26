# 演習 16 — ストアドプロシージャとユーザー定義関数

対象解説: [docs/16_stored_procedures.md](../docs/16_stored_procedures.md)
使用DB: `SalesLearning`(先頭で `USE SalesLearning;` を実行しておくこと)

各問、**まず自力でクエリを書いて実行** → 結果を確認 → 解答例
[solutions/16_stored_procedures.sql](solutions/16_stored_procedures.sql) と照合しましょう。
解答例と書き方が違っても、同じ結果になっていれば正解です。

> ⚠️ **この演習の約束(必ず守ること)**
> - 作成するプロシージャ名は **`usp_Ex16_` で始める**、関数名は **`fn_Ex16_` で始める**こと
>   (どれが演習用オブジェクトか一目で分かるようにするため)。
> - **各問の最後、または演習の最後に必ず `DROP PROCEDURE IF EXISTS` /
>   `DROP FUNCTION IF EXISTS` で後片付け**すること。サンプルDBを散らかさない。
> - **データを変更する問題は `BEGIN TRAN ... ROLLBACK` で囲む**こと(13 章と同じ方針)。
> - `CREATE PROCEDURE` / `CREATE FUNCTION` は **バッチの先頭**でなければならないので、
>   直前の文との間に `GO` を入れること。

---

## 基礎

**Q1.** 商品一覧を返すストアドプロシージャ `dbo.usp_Ex16_GetProducts` を作りなさい。
パラメータは無しで、`Products` から `ProductId` / `ProductName` / `UnitPrice` / `Discontinued`
を単価の降順で返すこと。**1行目に `SET NOCOUNT ON;` を書くこと**。
作成後に `EXEC` で呼び出して結果を確認しなさい。

**Q2.** Q1 のプロシージャを **`CREATE OR ALTER`** で作り直し、
「廃番(`Discontinued = 1`)を含めるかどうか」を切り替える
`@IncludeDiscontinued BIT = 0`(既定値は「含めない」)パラメータを追加しなさい。
そのうえで、次の3通りの呼び出しをそれぞれ試しなさい。

1. 引数なし(既定値で廃番を除外)
2. **名前付き**で `@IncludeDiscontinued = 1`
3. **位置指定**で `1`

**Q3.** 顧客ID を受け取り、その顧客の注文一覧
(`OrderId` / `OrderDate` / `ShipDate`)を注文日順に返すプロシージャ
`dbo.usp_Ex16_GetCustomerOrders` を作りなさい。
`@CustomerId INT` は既定値を持たない必須パラメータとすること。
作成後、顧客 1(注文あり)と顧客 11(注文なし)の両方で呼び出し、動作を確認しなさい。

**Q4.** Q1〜Q3 で作ったプロシージャを、`DROP PROCEDURE IF EXISTS` ですべて削除しなさい。
削除後、`sys.objects` を検索して **本当に消えたことを確認**しなさい
(ヒント: `type = 'P'` がストアドプロシージャ)。

---

## 応用

**Q5.** 顧客ID を受け取り、次の2つを **`OUTPUT` パラメータ** で返すプロシージャ
`dbo.usp_Ex16_CustomerStats` を作りなさい。

- `@OrderCount INT OUTPUT` … その顧客の注文件数
- `@TotalAmount DECIMAL(18,2) OUTPUT` … 売上合計
  (明細金額 = `Quantity * UnitPrice * (1 - Discount)`。注文が無ければ `0`)

作成後、顧客 1 と顧客 11 について呼び出し、受け取った値を `SELECT` で表示しなさい。
(ヒント: 呼び出し側の `EXEC` にも `OUTPUT` を書かないと値が返りません)

**Q6.** 商品ID を受け取り、次の **状態コードを `RETURN`** するプロシージャ
`dbo.usp_Ex16_CheckProduct` を作りなさい。

- `0` … 商品が存在し、販売中(`Discontinued = 0`)。あわせて商品情報を `SELECT` で返す
- `1` … 商品が存在するが廃番
- `2` … そもそも商品が存在しない

作成後、商品 1(販売中)/ 商品 5(廃番)/ 商品 999(存在しない)で呼び出し、
戻り値を変数で受け取って表示しなさい。
**なぜ「売上金額」のようなデータを `RETURN` で返してはいけないのか**も説明しなさい。

**Q7.** 注文ID と割引率を受け取り、その注文の **全明細の `Discount` を一括更新する**
プロシージャ `dbo.usp_Ex16_ApplyDiscount` を作りなさい。要件は次のとおり。

- `SET NOCOUNT ON;` と `SET XACT_ABORT ON;` を書く
- 注文が存在しなければ `THROW 50010, N'指定された注文が存在しません。', 1;`
- 割引率が `0.00` 未満または `1.00` より大きければ `THROW 50011, ...` でエラーにする
- 更新は `BEGIN TRY ... BEGIN TRAN ... COMMIT ... END TRY` の中で行い、
  `BEGIN CATCH` では `IF @@TRANCOUNT > 0 ROLLBACK;` のあと **引数なしの `THROW;`** で再送出する

呼び出しの確認は、**正常系を `BEGIN TRAN ... ROLLBACK` で囲んで**行い、
異常系(存在しない注文・不正な割引率)は呼び出し側の `TRY...CATCH` で
`ERROR_NUMBER()` と `ERROR_MESSAGE()` を表示して確認しなさい。

**Q8.** 明細金額(`Quantity * UnitPrice * (1 - Discount)`)を返す
**スカラー関数** `dbo.fn_Ex16_LineAmount` を作り、`OrderDetails` に適用して結果を確認しなさい。
そのうえで、**同じ計算を1列だけ返すインラインテーブル値関数**
`dbo.fn_Ex16_LineAmountTVF` として書き直し、`CROSS APPLY` で呼び出しなさい。
**スカラー関数がなぜ遅いのか**を2つ以上挙げなさい。

**Q9.** 地域(`Region`)を受け取り、その地域の顧客ごとに
`CustomerId` / `CustomerName` / 注文件数 / 売上合計 を返す
**インラインテーブル値関数** `dbo.fn_Ex16_RegionSales` を作りなさい。
作成後、`N'関東'` と `N'関西'` で呼び出し、売上合計の降順で表示しなさい。
(ヒント: iTVF は `RETURNS TABLE AS RETURN ( SELECT ... )` の **1文のみ**。
`BEGIN ... END` は書けません)

---

## チャレンジ

**Q10.** 顧客ID と件数 `@TopN` を受け取り、その顧客の **直近の注文を上位 N 件** 返す
インラインテーブル値関数 `dbo.fn_Ex16_LatestOrders` を作りなさい。
そのうえで、`Customers` 全件に対して **`OUTER APPLY`** で適用し、
「各顧客の直近2件の注文」を一覧しなさい。

さらに、**`CROSS APPLY` に変えると結果がどう変わるか**を実行して確認し、理由を説明しなさい。
(ヒント: 注文が1件も無い顧客が `Customers` に存在します)

**Q11.** Q9 と同じ集計を、今度は **多ステートメントテーブル値関数 (MSTVF)**
`dbo.fn_Ex16_RegionSalesMS` として書きなさい
(`RETURNS @Result TABLE (...)` の形)。
実行結果は Q9 と同じになるはずです。そのうえで、次を説明しなさい。

- MSTVF が iTVF に比べて不利になる理由(**推定行数**という言葉を使って)
- どちらを第一選択にすべきか

(ヒント: 実際に見積もりを見たい場合は SSMS の「推定実行プラン」を表示し、
関数のオペレータにマウスを乗せて `Estimated Number of Rows` を比較する)

**Q12.** 期間(`@FromDate` / `@ToDate`)を受け取り、**一時テーブルで段階的に処理する**
プロシージャ `dbo.usp_Ex16_SalesReport` を作りなさい。処理の流れは次のとおり。

1. `#TargetOrders` … 対象期間の注文(`OrderId` / `CustomerId` / `OrderDate`)を抽出
2. `#OrderAmount` … `#TargetOrders` に絞って、注文ごとの合計金額を集計
3. 最終結果 … 顧客ごとに「注文件数」「売上合計」「1注文あたり平均」を売上降順で返す

`2023-01-01` 〜 `2023-12-31` で実行して結果を確認しなさい。
プロシージャ内で作った `#一時テーブル` は、終了後にどうなるかも確認しなさい
(ヒント: 呼び出し側で `SELECT * FROM #TargetOrders;` を実行してみる)。

**Q13.** **後片付け**。この演習で作成したプロシージャ・関数を **すべて削除**しなさい。

- プロシージャ: `usp_Ex16_` で始まるもの
- 関数: `fn_Ex16_` で始まるもの

削除後、`sys.objects` を検索して **残っていないことを確認**しなさい。
(ヒント: `type IN ('P','FN','IF','TF')`。それぞれ プロシージャ / スカラー関数 /
インラインTVF / 多ステートメントTVF を表します)
