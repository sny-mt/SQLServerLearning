# 演習 17 — ユーザー定義型とテーブル値パラメータ (TVP)

対象解説: [docs/17_user_defined_types.md](../docs/17_user_defined_types.md)
使用DB: `SalesLearning`(先頭で `USE SalesLearning;` を実行しておくこと)

各問、**まず自力でクエリを書いて実行** → 結果を確認 → 解答例
[solutions/17_user_defined_types.sql](solutions/17_user_defined_types.sql) と照合しましょう。
解答例と書き方が違っても、同じ結果になっていれば正解です。

---

> ⚠️ **この演習の約束(必ず守ること)**
>
> 1. **オブジェクトを作ります**。型 (`TYPE`)・プロシージャ (`PROCEDURE`)・テーブルを作るので、
>    **最後の Q13 で必ず全部片付けてください**。
> 2. **後片付けには順序があります**。
>    **`DROP PROCEDURE` → `DROP TYPE`** の順です。
>    型を使っているプロシージャが残っていると `DROP TYPE` はエラー 3732 で失敗します。
>    「使っている側を先に消す」と覚えましょう。
> 3. **データを書き換える操作は `BEGIN TRAN ... ROLLBACK` で囲むか、一時テーブルで行うこと**。
>    `COMMIT` は絶対にしないでください(13章と同じ方針)。
> 4. `DECLARE` した変数は **バッチ (`GO`) をまたげません**。宣言と使用は同じバッチに書きます。

---

## 基礎

**Q1.** 別名データ型 `dbo.PhoneNumber` を、`NVARCHAR(20)` の `NOT NULL` として作成しなさい。
作成後、`sys.types` を検索して、その型が「ユーザー定義」として登録されていること、
および基になっている組み込み型・最大長を確認しなさい。
さらに、その型の変数を1つ宣言して `N'03-1234-5678'` を代入し、表示しなさい。
(ヒント: `sys.types` の `is_user_defined` 列で絞る。基の型名は `TYPE_NAME(system_type_id)`)

**Q2.** Q1 で作った `dbo.PhoneNumber` 型を使って、テーブル `dbo.CustomerPhones` を作りなさい。
列は `CustomerId INT` (主キー) と `Tel dbo.PhoneNumber` の2つとします。
作成後、`sys.columns` と `sys.types` を結合して「`PhoneNumber` 型を使っている列」を一覧しなさい。

**Q3.** Q2 の状態で `DROP TYPE dbo.PhoneNumber;` を実行し、**エラーになることを確認**しなさい。
エラー番号とメッセージを読み、なぜ失敗するのかを説明しなさい。
そのうえで、**正しい順序**で `dbo.CustomerPhones` と `dbo.PhoneNumber` の両方を片付けなさい。
(この後の問題ではもう使いません)

**Q4.** ユーザー定義テーブル型 `dbo.OrderDetailType` を、次の仕様で作成しなさい。

| 列 | 型 | 制約 |
|---|---|---|
| `ProductId` | `INT` | `NOT NULL`・**主キー** |
| `Quantity` | `INT` | `NOT NULL`・`CHECK` で 0 より大きいこと |
| `UnitPrice` | `DECIMAL(10, 0)` | `NULL` 可(NULL のときは商品の現在単価を使う約束) |
| `Discount` | `DECIMAL(4, 2)` | `NOT NULL`・**既定値 0**・`CHECK` で 0.00〜1.00 |

作成後、`sys.table_types` と `sys.columns` を結合して、この型の列構成を表示しなさい。
(ヒント: 結合キーは `sys.table_types.type_table_object_id`)

**Q5.** `dbo.OrderDetailType` 型の変数 `@Details` を宣言し、次の3行を入れなさい。

- 商品1(ノートPC)を 2 個・割引 10%
- 商品2(ワイヤレスマウス)を 5 個・割引なし(`Discount` を **列リストから省略** して既定値 0 が入ることを確認)
- 商品3(メカニカルキーボード)を 1 個・単価は `NULL`・割引 5%

そのうえで `dbo.Products` と結合し、**商品名・数量・採用単価・割引率・明細金額** を表示しなさい。
採用単価は「`UnitPrice` が `NULL` なら `Products.UnitPrice`」とし、
明細金額は `Quantity * 採用単価 * (1 - Discount)` で計算します。

**Q6.** Q5 の `@Details` に、**すでに入っている商品1をもう一度** `INSERT` しようとするとどうなりますか。
実際に試して確認し、なぜそうなるのかを説明しなさい。
(ヒント: 型定義に何を書いたか)

---

## 応用

**Q7.** テーブル値パラメータを受け取るストアドプロシージャ `dbo.usp_RegisterOrder` を作りなさい。
仕様:

- パラメータ: `@CustomerId INT` / `@EmployeeId INT` / `@OrderDate DATE` /
  `@Details dbo.OrderDetailType` / `@NewOrderId INT OUTPUT`
- 明細が **0 行なら** `THROW 50001` でエラーにする。
- `dbo.Products` に存在しない `ProductId` が含まれていたら `THROW 50002` でエラーにする。
- 新しい `OrderId` は `MAX(OrderId) + 1` で採番し、`@NewOrderId` で返す
  (このサンプルDBの `Orders.OrderId` は `IDENTITY` ではありません)。
- `dbo.Orders` に1行、`dbo.OrderDetails` に明細を **`INSERT ... SELECT` で一括** 登録する。
  `ShipDate` は `NULL`(未出荷)とする。
- 明細の単価は「TVP の `UnitPrice` が `NULL` なら `Products.UnitPrice`」を採用する。

作成したら、**`BEGIN TRAN ... ROLLBACK` で囲んで** 実行し、
顧客1・担当2・注文日 2024-02-01 で、商品1を1個(割引5%)・商品2を3個・商品16を2個(割引10%)
の注文を登録して、登録結果を `SELECT` で確認しなさい。

(ヒント: TVP のパラメータには必ずあるキーワードが要ります)

**Q8.** Q7 のプロシージャで、`@Details` の `READONLY` を **わざと外して** 作成しようとするとどうなりますか。
エラー番号とメッセージを確認しなさい。
また、`READONLY` を付けた正しいプロシージャの中で
`UPDATE @Details SET Quantity = 0;` を書こうとするとどうなるかも確認しなさい。
プロシージャ内で明細の内容を **加工したい** 場合、どうすればよいかを述べなさい。

**Q9.** 既存の注文明細を「送られてきた内容にそろえる」プロシージャ
`dbo.usp_MergeOrderDetails` を作りなさい。仕様:

- パラメータ: `@OrderId INT` / `@Details dbo.OrderDetailType`
- `MERGE` を使い、
  - 一致する明細があり内容が違う → **UPDATE**
  - ターゲットに無い → **INSERT**
  - ソース(TVP)に無い → **DELETE**
- `OUTPUT $action` で、どの行がどう処理されたかを返す。

作成したら `BEGIN TRAN ... ROLLBACK` で囲み、注文 `1001` に対して
「商品1を10個・割引20%」「商品9を50個・割引なし」の2行を渡して実行し、結果を確認しなさい。

> ⚠️ **`WHEN NOT MATCHED BY SOURCE` には落とし穴があります。**
> ターゲットは `dbo.OrderDetails` 全体です。何も対策しないと **他の注文の明細まで消えます**。
> どう書けば安全かを考えてから実行してください。

**Q10.** 「1行ずつ N 回呼ぶ」方式と「TVP で1回呼ぶ」方式を比較しなさい。

- 明細を1行だけ登録するプロシージャ `dbo.usp_AddOrderDetail`
  (`@OrderId INT` / `@ProductId INT` / `@Quantity INT`)を作る。
- `BEGIN TRAN` の中で一時的な注文を1件作り、`WHILE` ループで
  `dbo.usp_AddOrderDetail` を **10 回** 呼んで明細10行を登録する。
- 同じ10行を、`dbo.OrderDetailType` の変数に詰めて **1回の `INSERT ... SELECT`** で登録する。
- 最後は `ROLLBACK`。

両者の結果は同じになります。そのうえで、
**このスクリプト上では見えない「本当の差」がどこにあるのか**を説明しなさい。
(ヒント: アプリケーションと SQL Server の間で何が 10 回起きているか)

---

## チャレンジ

**Q11.** 大量行の TVP を想定して、`dbo.usp_RegisterOrderLarge` を作りなさい。
Q7 と同じ動作をしますが、**受け取った TVP をいったん一時テーブル `#Details` に写してから**
処理するようにします。`#Details` には `ProductId` の主キーを付けること。

そのうえで、**なぜわざわざ写すのか**を、TVP の実体が何であるかに触れて説明しなさい。
また、写す以外の対策も1つ挙げなさい。
(ヒント: [docs/15_temp_tables.md](../docs/15_temp_tables.md) のテーブル変数の性質)

**Q12.** `dbo.OrderDetailType` の `Discount` 列を `DECIMAL(4, 2)` から
`DECIMAL(5, 3)`(0.125 のような3桁の割引率を扱いたい)に **変更** しなさい。

まず `ALTER TYPE` で変更できないこと、`DROP TYPE` がそのままでは失敗することを確認し、
**正しい手順**(依存オブジェクトの調査 → 削除 → 型の再作成 → プロシージャの再作成)で実施しなさい。

- 依存の調査には `sys.parameters` と `sys.types` の結合を使うこと。
- 再作成後、`sys.table_types` + `sys.columns` で `Discount` の `precision` / `scale` が
  変わったことを確認しなさい。

**Q13.** **後片付け**。この演習で作成したオブジェクトを **正しい順序で** すべて削除しなさい。

- 対象: `dbo.usp_RegisterOrder` / `dbo.usp_MergeOrderDetails` / `dbo.usp_AddOrderDetail` /
  `dbo.usp_RegisterOrderLarge` / `dbo.OrderDetailType`
  (`dbo.CustomerPhones` と `dbo.PhoneNumber` は Q3 で片付け済み)
- すべて `IF EXISTS` 付きで書き、**プロシージャ → 型** の順にすること。
- 削除後、`sys.types` と `sys.table_types` を検索して
  **ユーザー定義型が1つも残っていない**ことを確認しなさい。
- 最後に `dbo.Orders` / `dbo.OrderDetails` の行数が元どおり(20 行 / 42 行)であることも確認しなさい。
