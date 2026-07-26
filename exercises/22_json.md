# 演習 22 — JSON操作

対象解説: [docs/22_json.md](../docs/22_json.md)
使用DB: `SalesLearning`(先頭で `USE SalesLearning;` を実行しておくこと)

各問、**まず自力でクエリを書いて実行** → 結果を確認 → 解答例
[solutions/22_json.sql](solutions/22_json.sql) と照合しましょう。
解答例と書き方が違っても、同じ結果になっていれば正解です。

> ⚠️ **バージョン前提**: 本演習の JSON 関数はすべて **SQL Server 2016 (13.x) 以降** が必要です。
> また `OPENJSON` は **データベースの互換性レベル 130 以上** で動作します。
> 実行前に確認しておきましょう。
>
> ```sql
> SELECT @@VERSION AS サーバーバージョン;
> SELECT name, compatibility_level FROM sys.databases WHERE name = N'SalesLearning';
> ```

> ⚠️ **後片付けの約束**: テーブルを作る問題は **一時テーブル(`#名前`)** か
> **`BEGIN TRAN ... ROLLBACK`** で囲み、最後に `DROP TABLE` / `DROP INDEX` まで
> 必ず実行してください。サンプルDBを汚さないこと。

---

## 演習で使う JSON リテラル

以下の2つを、必要な問でそのままコピーして使ってください
(**日本語を含むので `N'...'` を外さないこと**)。

**A. 単一の注文(オブジェクト)**

```sql
DECLARE @order NVARCHAR(MAX) = N'
{
  "orderId": 2001,
  "orderDate": "2024-02-01",
  "shipDate": null,
  "customer": { "customerId": 1, "customerName": "アルファ商事", "city": "東京" },
  "lines": [
    { "productId": 1,  "productName": "ノートPC",         "quantity": 2, "unitPrice": 128000, "discount": 0.10 },
    { "productId": 2,  "productName": "ワイヤレスマウス", "quantity": 5, "unitPrice": 2800,   "discount": 0.00 },
    { "productId": 16, "productName": "SQL実践ガイド",     "quantity": 3, "unitPrice": 3200,   "discount": 0.05 }
  ]
}';
```

**B. 複数の注文(配列。各注文がさらに明細配列を持つ)**

```sql
DECLARE @orders NVARCHAR(MAX) = N'
[
  { "orderId": 2001, "orderDate": "2024-02-01",
    "customer": { "customerId": 1, "customerName": "アルファ商事" },
    "lines": [ { "productId": 1,  "quantity": 2,  "unitPrice": 128000, "discount": 0.10 },
               { "productId": 2,  "quantity": 5,  "unitPrice": 2800,   "discount": 0.00 } ] },
  { "orderId": 2002, "orderDate": "2024-02-03",
    "customer": { "customerId": 3, "customerName": "ガンマ物産" },
    "lines": [ { "productId": 6,  "quantity": 1,  "unitPrice": 32000,  "discount": 0.00 },
               { "productId": 9,  "quantity": 20, "unitPrice": 150,    "discount": 0.20 },
               { "productId": 16, "quantity": 4,  "unitPrice": 3200,   "discount": 0.05 } ] },
  { "orderId": 2003, "orderDate": "2024-02-05",
    "customer": { "customerId": 5, "customerName": "イプシロン食品" },
    "lines": [ { "productId": 13, "quantity": 10, "unitPrice": 980,    "discount": 0.00 } ] }
]';
```

---

## 基礎

**Q1.** `ISJSON()` を使って、次の4つの文字列がそれぞれ JSON として妥当かどうかを
1行で並べて確認しなさい。結果がどう変わるかを説明できるようにすること。

1. `N'{"orderId": 2001}'`
2. `N'[1, 2, 3]'`
3. `N'{"orderId": 2001'` (閉じ括弧が無い)
4. `NULL`

**Q2.** JSON リテラル **A** から、`JSON_VALUE()` を使って次の4つを取り出しなさい。

- 注文番号(`orderId`)— **INT に変換すること**
- 注文日(`orderDate`)— **DATE に変換すること**
- 顧客名(`customer.customerName`)
- 明細の **1件目** の商品名(`lines[0].productName`)

**Q3.** JSON リテラル **A** に対して、`JSON_VALUE()` と `JSON_QUERY()` の違いを
1つの `SELECT` で並べて確認しなさい。次の4つを出力すること。

- `JSON_VALUE(@order, '$.customer')`
- `JSON_QUERY(@order, '$.customer')`
- `JSON_VALUE(@order, '$.orderId')`
- `JSON_QUERY(@order, '$.orderId')`

そのうえで、**どちらが NULL になり、なぜそうなるのか** をコメントで説明しなさい。
さらに、`strict` モードにすると挙動がどう変わるかも確かめなさい。

(ヒント: 「値なら VALUE、かたまりなら QUERY」)

**Q4.** JSON リテラル **A** に対して `OPENJSON()` を **`WITH` 句なし**(既定スキーマ)で使い、
最上位のプロパティを `key` / `value` / `type` の3列で一覧しなさい。
`type` 列の値がそれぞれ何を意味するか(0〜5)を説明できるようにすること。

続けて、`$.lines` を起点にした既定スキーマの結果も確認し、
オブジェクトのときと配列のときで `key` 列の中身がどう違うかを述べなさい。

**Q5.** JSON リテラル **A** の `lines` 配列を、`OPENJSON ... WITH` を使って
次の列を持つ表に展開しなさい。

| 列名 | 型 |
|---|---|
| ProductId | INT |
| ProductName | NVARCHAR(100) |
| Quantity | INT |
| UnitPrice | DECIMAL(12,2) |
| Discount | DECIMAL(5,2) |

さらに **明細金額**(`Quantity * UnitPrice * (1 - Discount)`)の列を追加し、
`ProductId` 順に並べなさい。

---

## 応用

**Q6.** JSON リテラル **B**(注文の配列)に対して、`AS JSON` と `CROSS APPLY OPENJSON` を使い、
**注文1行 × 明細1行** に展開しなさい。出力列は次のとおり。

- OrderId / OrderDate / CustomerName / ProductId / Quantity / 明細金額

さらに `dbo.Products` と `LEFT JOIN` して **商品名** の列も加えなさい。

続けて、同じ展開結果を集計して **注文ごとの合計金額と明細件数** を求め、
合計金額の降順で並べなさい。

(ヒント: 子配列は `NVARCHAR(MAX) '$.lines' AS JSON` で受ける)

**Q7.** `dbo.Customers` から、`CustomerId` が 1・3・9 の顧客について、
`FOR JSON PATH` を使って次の形の JSON を作りなさい。

```json
{ "customers": [
    { "customerId": 1, "customerName": "アルファ商事",
      "address": { "city": "東京", "region": "関東" },
      "salesRep": { "employeeId": 2, "name": "鈴木花子" } },
    ...
] }
```

- ルート要素の名前は `customers` とすること。
- `address` と `salesRep` は **ネストしたオブジェクト** にすること。
- 担当営業(`SalesRepId`)は `dbo.Employees` と **外部結合** すること
  (顧客9は担当者が NULL)。担当者がいない顧客で `salesRep` がどうなるか確認しなさい。

**Q8.** 次の3つを比較しなさい。

1. `dbo.Customers` と `dbo.Orders` を結合した結果を **`FOR JSON AUTO`** で出力する
   (`CustomerId` が 1・2 の顧客に限定)。**`ORDER BY` を付けた場合と付けない場合**の
   出力の違いを確認すること。
2. `dbo.Orders` の `OrderId` 1005・1006 について、`orderId` と `shipDate` を
   `FOR JSON PATH` で出力する。**`INCLUDE_NULL_VALUES` を付けた場合と付けない場合**の
   違いを確認すること(1006 は未出荷)。
3. `CustomerId = 1` の顧客1件を `FOR JSON PATH, WITHOUT_ARRAY_WRAPPER` で
   **単一オブジェクト** として出力する。複数行返るクエリに同じオプションを付けると
   どうなるかも確認し、なぜ危険かを説明しなさい。

**Q9.** JSON リテラル **A** に対して `JSON_MODIFY()` を使い、次の5つをそれぞれ実行しなさい。

1. `shipDate` を `'2024-02-05'` に更新する
2. 存在しないプロパティ `status` に `N'出荷済'` を **追加** する
3. `customer.city` を **削除** する
4. `orderDate` を **null にする**(削除ではない)
5. `lines` 配列の末尾に
   `{"productId":10,"quantity":12,"unitPrice":280,"discount":0.00}` を **追加** する

最後に、1・2・3 を **まとめて1文** で適用した JSON を出力しなさい。

(ヒント: 3 と 4 の違いはモード。5 は `append` 修飾子と `JSON_QUERY`)

---

## チャレンジ

**Q10.** `dbo.Customers` / `dbo.Orders` / `dbo.OrderDetails` / `dbo.Products` を使って、
**顧客 → 注文 → 明細** の3階層を持つ1つの JSON を作りなさい。対象は `CustomerId` が 1・3・11。

要件:

- ルート名は `customers`。
- 顧客レベル: `customerId` / `customerName` / `address.city` / `address.region`
- 注文レベル(配列 `orders`): `orderId` / `orderDate` / `shipDate` / `totalAmount`
  (`totalAmount` はその注文の明細金額合計)
- 明細レベル(配列 `details`): `productId` / `productName` / `quantity` / `unitPrice` / `amount`
- 配列は `orderId` 昇順・`productId` 昇順に並べること。
- **顧客11(注文なし)でも `"orders": []`(空配列)が出力される**ようにすること。

(ヒント: 子配列は相関サブクエリ + `FOR JSON PATH`。空配列は `COALESCE(..., N'[]')` を
`JSON_QUERY` で包む)

**Q11.** 一時テーブルを使って、**JSON 列 + CHECK 制約 + PERSISTED 計算列 + インデックス** の
一連の流れを実装しなさい。

1. 一時テーブル `#ApiOrders`(`ApiOrderId` IDENTITY 主キー、`Payload NVARCHAR(MAX) NOT NULL`)を作る。
   `Payload` には **`CHECK (ISJSON(Payload) = 1)`** を付けること。
2. `{"orderId":n,"customer":{"customerId":…},"status":"完了" または "保留"}` という形の
   JSON を **1万件** 投入する(`customerId` は 1〜12 を巡回、20件に1件を `保留` にする)。
3. 壊れた JSON を1件 INSERT してみて、CHECK 制約で弾かれることを `TRY ... CATCH` で確認する。
4. `WHERE JSON_VALUE(Payload, '$.customer.customerId') = N'7'` で件数を数え、
   `SET STATISTICS IO ON` と実行プランで **スキャンになる** ことを確認する。
5. `CustomerId` という **`PERSISTED` 計算列**(`JSON_VALUE` を INT に CAST)を追加し、
   `IX_ApiOrders_CustomerId` という非クラスタ化インデックスを張る。
6. 計算列で同じ検索を行い、**インデックスシークになる** ことを確認する。
7. `DROP INDEX` → `DROP TABLE` で **後片付け** する。

なぜ 4 ではインデックスが効かず、6 では効くのかを説明できるようにしなさい
(参考: [18 インデックスと実行プラン](../docs/18_indexes_execution_plans.md))。

**Q12.** JSON リテラル **B** を「API から受け取った注文データ」と見なし、
**正規化された一時テーブルへ取り込む(ステージング)** 処理を書きなさい。

1. `#StagingOrders`(OrderId 主キー / CustomerId / OrderDate)と
   `#StagingOrderDetails`(OrderId + ProductId 複合主キー / Quantity / UnitPrice / Discount)を作る。
2. `OPENJSON ... WITH` でヘッダを `#StagingOrders` に INSERT する。
3. `AS JSON` + `CROSS APPLY OPENJSON` で明細を `#StagingOrderDetails` に INSERT する。
4. 取り込んだ内容を確認し、`dbo.Customers` / `dbo.Products` と結合して
   **注文番号・顧客名・商品名・明細金額** を表示する。
5. 取り込んだ `CustomerId` が `dbo.Customers` に **実在するか** を検証するクエリを書く
   (実在しない顧客IDがあれば列挙する)。
6. 両方の一時テーブルを `DROP TABLE` する。

最後に、「なぜ JSON をそのまま `NVARCHAR(MAX)` 列に置いたままにせず、
検索軸となる列を正規化テーブルに取り出すのか」を、**外部キー・インデックス・部分更新** の
3つの観点から説明しなさい。
