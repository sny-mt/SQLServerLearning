# 22 JSON操作

> **このトピックのゴール**: SQL Server の JSON 機能を使って、
> **JSON を読んで表にする**(`ISJSON` / `JSON_VALUE` / `JSON_QUERY` / `OPENJSON`)、
> **表から JSON を組み立てる**(`FOR JSON AUTO` / `FOR JSON PATH`)、
> **JSON を部分的に書き換える**(`JSON_MODIFY`)の3方向を自在に扱えるようになる。
> さらに、JSON を列に保存する設計の是非と、**計算列＋インデックス**による
> 高速検索まで押さえ、「何をJSONにして、何をリレーショナルにするか」を判断できるようになる。
>
> **前提**: [21 実務頻出クエリパターン集](21_query_patterns.md) までを済ませ、
> `JOIN` / サブクエリ / [14 APPLY](14_apply.md) / [18 インデックスと実行プラン](18_indexes_execution_plans.md)
> を理解していること。`SalesLearning` を構築済みであること。

すべての例は先頭で `USE SalesLearning;` を実行済みとします。

> ⚠️ **バージョン前提 — JSON 関数は SQL Server 2016 (13.x) 以降**
> 本章で扱う `ISJSON` / `JSON_VALUE` / `JSON_QUERY` / `OPENJSON` / `JSON_MODIFY` / `FOR JSON` は
> **すべて SQL Server 2016 以降**の機能です。2014 以前では一切使えません。
> さらに `OPENJSON` は **データベースの互換性レベルが 130 以上** でないと使えません
> (SQL Server 2019 上でも、DB の互換性レベルが 120 のままだとエラーになります)。
>
> ```sql
> -- 自分の環境を確認する
> SELECT @@VERSION AS サーバーバージョン;
> SELECT name, compatibility_level
> FROM   sys.databases
> WHERE  name = N'SalesLearning';     -- 130 以上であること
> ```
>
> 本章で **2016 より新しいバージョンを要求する機能** を紹介するときは、その都度明記します。

## 1. SQL Server の JSON サポート全体像

SQL Server の JSON は、XML と違って **専用のデータ型を持ちません**
(SQL Server 2025 / Azure SQL で登場した `json` 型は本章の対象外)。
JSON は **ただの `NVARCHAR` 文字列** として扱い、それを解釈する **関数群** が提供されている、
という設計です。

| 方向 | 使うもの | 用途 |
|---|---|---|
| 検証 | `ISJSON()` | 文字列が正しい JSON かを判定 |
| 読む(スカラー) | `JSON_VALUE()` | 数値・文字列など **1つの値** を取り出す |
| 読む(構造) | `JSON_QUERY()` | **オブジェクト / 配列** をそのまま取り出す |
| 読む(表化) | `OPENJSON()` | JSON を **行と列** に展開する(テーブル値関数) |
| 書く | `FOR JSON AUTO` / `FOR JSON PATH` | クエリ結果を JSON 文字列にする |
| 更新 | `JSON_MODIFY()` | JSON の一部だけを書き換える |

この「関数だけ」という割り切りのおかげで、既存の `NVARCHAR(MAX)` 列に入っている
JSON をそのまま扱えますし、JSON を返す API のレスポンスを一時変数に受けて
即座にクエリすることもできます。

本章を通して、次の2つの JSON リテラルを題材にします
(**API から受け取った注文データ**という想定です)。

```sql
-- 単一の注文(オブジェクト)
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

```sql
-- 複数の注文(配列)。各注文がさらに明細配列を持つ = 二重のネスト
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

- 日本語を含む JSON リテラルは **必ず `N'...'`** を付けます。付け忘れると `?` に化けます。
- JSON の中にシングルクォートを含めたい場合は、T-SQL の流儀どおり `''`(2個)にします。

---

# 【読む】JSON → 表

## 2. ISJSON() — まず「本当に JSON か」を確かめる

`ISJSON(式)` は、文字列が正しい JSON なら **1**、そうでなければ **0**、
入力が NULL なら **NULL** を返します。

```sql
SELECT ISJSON(N'{"a":1}')          AS オブジェクト,   -- 1
       ISJSON(N'[1,2,3]')          AS 配列,           -- 1
       ISJSON(N'{"a":1')           AS 壊れたJSON,     -- 0
       ISJSON(N'ただの文字列')      AS 文字列,         -- 0
       ISJSON(CAST(NULL AS NVARCHAR(MAX))) AS NULL入力; -- NULL
```

用途は主に3つです。

1. **入力の検証**(外部からもらった文字列を処理する前に弾く)
2. **`CHECK` 制約**(JSON 列に壊れた値が入るのを防ぐ → 第12節)
3. **`WHERE` での安全な絞り込み**(JSON でない行を先に除外してから `JSON_VALUE` を適用)

```sql
-- 「JSON でない行」を除外してから値を取り出す(安全な形)
DECLARE @candidate NVARCHAR(MAX) = N'{"orderId": 2001}';

SELECT CASE WHEN ISJSON(@candidate) = 1
            THEN JSON_VALUE(@candidate, '$.orderId')
            ELSE NULL
       END AS OrderId;
```

> ⚠️ `ISJSON` は **構文が JSON として正しいか** だけを見ます。
> 「必要なプロパティが揃っているか」「型が期待どおりか」は検証しません。
> スキーマ検証をしたいなら `OPENJSON ... WITH` で受けて `NULL` チェックする、
> という形になります。

> 📌 **SQL Server 2022 (16.x) 以降** では第2引数で種類を指定できます:
> `ISJSON(式, VALUE | ARRAY | OBJECT | SCALAR)`。
> 例えば `ISJSON(@j, ARRAY) = 1` で「配列であること」まで確認できます。
> 2016〜2019 では使えません。

## 3. JSON_VALUE と JSON_QUERY — 何を取り出すかで使い分ける

この2つは **初学者がもっとも混同するポイント** です。
違いは「取り出す対象が **スカラー値** か **構造(オブジェクト/配列)** か」だけです。

| 関数 | 取り出せるもの | 戻り値の型 | 対象外を指定したときの挙動(lax) |
|---|---|---|---|
| `JSON_VALUE(式, パス)` | 文字列・数値・true/false・null といった **スカラー1個** | `NVARCHAR(4000)` | **NULL** を返す |
| `JSON_QUERY(式, パス)` | **オブジェクト `{}` / 配列 `[]`** | `NVARCHAR(MAX)` | **NULL** を返す |

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

SELECT
    JSON_VALUE(@order, '$.orderId')                AS 注文番号,      -- 2001
    JSON_VALUE(@order, '$.customer.customerName')  AS 顧客名,        -- アルファ商事
    JSON_VALUE(@order, '$.lines[0].productName')   AS 明細1商品名,   -- ノートPC
    JSON_VALUE(@order, '$.shipDate')               AS 出荷日,        -- NULL (JSON の null)
    JSON_VALUE(@order, '$.customer')               AS 顧客_VALUEで取得, -- NULL! (オブジェクトなので取れない)
    JSON_QUERY(@order, '$.customer')               AS 顧客_QUERYで取得, -- {"customerId":1,...}
    JSON_QUERY(@order, '$.lines')                  AS 明細配列,        -- [ {...}, {...}, {...} ]
    JSON_QUERY(@order, '$.orderId')                AS 注文番号_QUERYで取得; -- NULL! (スカラーなので取れない)
```

覚え方は **「値なら VALUE、かたまりなら QUERY」** です。

### 戻り値は必ず文字列 — 型が要るときは CAST する

`JSON_VALUE` は元の JSON が数値でも **`NVARCHAR(4000)` を返します**。
そのまま並べ替えたり比較したりすると **文字列としての比較** になり、事故ります。

```sql
DECLARE @order NVARCHAR(MAX) = N'{"orderId": 2001, "orderDate": "2024-02-01", "amount": 100}';

SELECT
    JSON_VALUE(@order, '$.amount')                          AS 文字列のまま,   -- '100'
    CAST(JSON_VALUE(@order, '$.amount')   AS DECIMAL(12,2)) AS 金額,
    CAST(JSON_VALUE(@order, '$.orderDate') AS DATE)          AS 注文日;
```

- **数値・日付として扱うなら必ず `CAST` / `TRY_CAST`**。
- 外部データで型が保証できないときは、エラーで止まらない **`TRY_CAST`** が実務的です。

> ⚠️ `JSON_VALUE` の戻り値は最大 **4000 文字** です。
> それより長い値を指すと lax モードでは **NULL**、strict モードでは **エラー** になります。
> 長い文字列は `JSON_QUERY`(nvarchar(max))や `OPENJSON ... WITH (col NVARCHAR(MAX) '$.path')` で受けます。

### JSON_QUERY はエスケープを防ぐ道具でもある

後述の `FOR JSON` / `JSON_MODIFY` で「JSON を JSON の中に埋め込む」とき、
素の文字列を渡すと `\"` だらけにエスケープされてしまいます。
`JSON_QUERY` で包むと **JSON として** 埋め込まれます(第10・11節で再登場)。

```sql
-- ✗ 文字列として埋め込まれる → "customer":"{\"id\":1}"
SELECT N'{"id":1}' AS customer FOR JSON PATH;

-- ○ JSON として埋め込まれる → "customer":{"id":1}
SELECT JSON_QUERY(N'{"id":1}') AS customer FOR JSON PATH;
```

## 4. パス式 — `$` 記法と lax / strict

JSON 関数の第2引数は **JSON パス式** です。書式は
`[lax | strict] $.プロパティ.プロパティ[添字]` です。

| 記法 | 意味 |
|---|---|
| `$` | ドキュメントのルート |
| `$.a` | ルート直下のプロパティ `a` |
| `$.a.b` | `a` の中の `b`(何段でもつなげられる) |
| `$[0]` | ルートが配列のときの **先頭要素**(添字は **0 始まり**) |
| `$.lines[2].productId` | 配列の3番目の要素の `productId` |
| `$."order id"` | キーに空白や記号を含むときはダブルクォートで囲む |

```sql
DECLARE @arr NVARCHAR(MAX) = N'[ {"id":10,"tags":["A","B"]}, {"id":20,"tags":["C"]} ]';

SELECT JSON_VALUE(@arr, '$[0].id')       AS 先頭のid,      -- 10
       JSON_VALUE(@arr, '$[1].tags[0]')  AS 2件目のタグ1,  -- C
       JSON_QUERY(@arr, '$[0].tags')     AS 先頭のタグ配列; -- ["A","B"]
```

```sql
-- キーに空白が入る場合
DECLARE @j NVARCHAR(MAX) = N'{"order id": 2001, "顧客名": "アルファ商事"}';

SELECT JSON_VALUE(@j, '$."order id"') AS 注文番号,
       JSON_VALUE(@j, '$."顧客名"')    AS 顧客名;
```

### lax モードと strict モード

パスの先頭に `lax` か `strict` を書けます。**省略時は `lax`** です。

| モード | 存在しないパス | 型が合わないパス(オブジェクトを `JSON_VALUE` 等) |
|---|---|---|
| `lax`(既定) | **NULL を返す** | **NULL を返す** |
| `strict` | **エラー** | **エラー** |

```sql
DECLARE @order NVARCHAR(MAX) = N'{"orderId": 2001, "customer": {"customerId": 1}}';

-- lax(既定): 存在しないプロパティは静かに NULL
SELECT JSON_VALUE(@order, '$.notExists')      AS lax省略,
       JSON_VALUE(@order, 'lax $.notExists')  AS lax明示;

-- strict: 存在しないプロパティはエラー
--   Msg 13608: Property cannot be found on the specified JSON path.
SELECT JSON_VALUE(@order, 'strict $.notExists') AS strictはエラー;

-- strict: 型が合わなくてもエラー(customer はオブジェクトなので JSON_VALUE 不可)
SELECT JSON_VALUE(@order, 'strict $.customer') AS これもエラー;
```

使い分けの指針:

- **`lax`(既定)** … 「あるかもしれないし、ないかもしれない」項目を読むとき。
  外部 API のオプション項目など。**実務ではこちらが基本**。
- **`strict`** … 「絶対にあるはず」の必須項目を読むとき。
  仕様違反のデータを **静かな NULL ではなくエラーで気づきたい** ときに有効。

> ⚠️ lax は便利ですが、**パス名のタイプミスも静かに NULL になります**。
> JSON のキーは **大文字小文字を区別する** ので、`$.orderid` と `$.orderId` は別物です。
> 「なぜか全部 NULL」のときは、まずキー名の綴りと大小文字を疑ってください。

## 5. OPENJSON(1) — 既定スキーマ(key / value / type の3列)

`OPENJSON` は **テーブル値関数** です。`FROM` 句に書いて、JSON を行に展開します。
`WITH` 句を付けない **既定スキーマ** では、常に次の3列が返ります。

| 列 | 内容 |
|---|---|
| `key` | オブジェクトなら **プロパティ名**、配列なら **0 始まりの添字**(nvarchar(4000)) |
| `value` | その値(nvarchar(max))。オブジェクト/配列なら JSON テキストのまま |
| `type` | 値の種類を表す **int**(下表) |

| `type` | 意味 |
|---|---|
| 0 | null |
| 1 | 文字列 |
| 2 | 数値 |
| 3 | true / false |
| 4 | 配列 |
| 5 | オブジェクト |

```sql
DECLARE @order NVARCHAR(MAX) = N'
{
  "orderId": 2001,
  "orderDate": "2024-02-01",
  "shipDate": null,
  "customer": { "customerId": 1, "customerName": "アルファ商事" },
  "lines": [ { "productId": 1, "quantity": 2 } ]
}';

-- 最上位のプロパティを一覧する(JSON の構造を調べるときの定番)
SELECT [key], [value], [type]
FROM   OPENJSON(@order);
```

結果のイメージ:

| key | value | type |
|---|---|---|
| orderId | 2001 | 2 |
| orderDate | 2024-02-01 | 1 |
| shipDate | NULL | 0 |
| customer | {"customerId":1,"customerName":"アルファ商事"} | 5 |
| lines | [{"productId":1,"quantity":2}] | 4 |

- `key` / `value` / `type` は **予約語なので角括弧 `[ ]` で囲む** のが安全です。
- 第2引数にパスを渡すと、**そこを起点に展開** します。

```sql
-- 明細配列を展開 → key が 0,1,2 の添字になり、value に各要素の JSON が入る
SELECT [key] AS 添字, [value] AS 要素JSON, [type]
FROM   OPENJSON(@order, '$.lines');
```

既定スキーマは、**構造が事前に分からない JSON を調査する** ときに非常に便利です。
逆に、構造が分かっているなら次節の `WITH` を使います。

## 6. OPENJSON(2) — WITH 句で明示的なスキーマを与える

`WITH` を付けると、**列名・型・JSON パス** を自分で定義して「普通のテーブル」として
扱えるようになります。**実務ではこちらが主役**です。

```sql
DECLARE @order NVARCHAR(MAX) = N'
{
  "orderId": 2001,
  "orderDate": "2024-02-01",
  "customer": { "customerId": 1, "customerName": "アルファ商事", "city": "東京" },
  "lines": [
    { "productId": 1,  "productName": "ノートPC",         "quantity": 2, "unitPrice": 128000, "discount": 0.10 },
    { "productId": 2,  "productName": "ワイヤレスマウス", "quantity": 5, "unitPrice": 2800,   "discount": 0.00 },
    { "productId": 16, "productName": "SQL実践ガイド",     "quantity": 3, "unitPrice": 3200,   "discount": 0.05 }
  ]
}';

-- 明細配列を「表」に展開し、明細金額まで計算する
SELECT  l.ProductId,
        l.ProductName,
        l.Quantity,
        l.UnitPrice,
        l.Discount,
        CAST(l.Quantity * l.UnitPrice * (1 - l.Discount) AS DECIMAL(12,2)) AS 明細金額
FROM    OPENJSON(@order, '$.lines')
        WITH (
            ProductId   INT             '$.productId',
            ProductName NVARCHAR(100)   '$.productName',
            Quantity    INT             '$.quantity',
            UnitPrice   DECIMAL(12,2)   '$.unitPrice',
            Discount    DECIMAL(5,2)    '$.discount'
        ) AS l
ORDER BY l.ProductId;
```

ポイント:

- `列名 型 'JSONパス'` の3点セットで1列を定義します。
- **パスは省略できます**。省略すると **列名と同じ名前のプロパティ** を探します
  (`quantity INT` は `$.quantity` を見る)。ただし JSON のキーは大小文字を区別するので、
  日本語の列名を付けたい場合などは **パスを明示するほうが安全**です。
- 型変換は `OPENJSON` が行うので、`JSON_VALUE` のような `CAST` の山になりません。
  **これが `WITH` を使う最大の利点**です。
- 型が合わない値があると **エラー**になります。落としたくないときは
  `NVARCHAR(MAX)` で受けてから `TRY_CAST` してください。

### 親の値と子の配列を同時に取る

`WITH` のパスは配列の要素からの相対パスですが、`$.` の起点を変えれば
親要素の値も一緒に取れます。「注文ヘッダ + 明細」を1文で取るときの定番です。

```sql
-- ヘッダ側は JSON_VALUE、明細側は OPENJSON WITH で取る
SELECT  CAST(JSON_VALUE(@order, '$.orderId')  AS INT)  AS OrderId,
        CAST(JSON_VALUE(@order, '$.orderDate') AS DATE) AS OrderDate,
        JSON_VALUE(@order, '$.customer.customerName')   AS CustomerName,
        l.ProductId,
        l.Quantity
FROM    OPENJSON(@order, '$.lines')
        WITH (ProductId INT '$.productId', Quantity INT '$.quantity') AS l;
```

### AS JSON — 子の構造をそのまま次段へ渡す

列の型を `NVARCHAR(MAX)` にして末尾に **`AS JSON`** を付けると、
その列に **オブジェクト/配列を JSON テキストのまま** 受け取れます。
これが次節のネスト展開の鍵になります。

```sql
SELECT o.orderId, o.customerName, o.lines
FROM   OPENJSON(N'[{"orderId":2001,"customer":{"customerName":"アルファ商事"},"lines":[{"productId":1}]}]')
       WITH (
           orderId      INT            '$.orderId',
           customerName NVARCHAR(50)   '$.customer.customerName',
           lines        NVARCHAR(MAX)  '$.lines' AS JSON   -- ← 配列をそのまま受ける
       ) AS o;
```

> ⚠️ `AS JSON` を付ける列は **必ず `NVARCHAR(MAX)`** でなければなりません。
> `NVARCHAR(100) ... AS JSON` はエラーです。
> 逆に、`AS JSON` を付けずにオブジェクト/配列のパスを指定すると、lax では **NULL**、
> strict では **エラー** になります(`JSON_VALUE` と同じ理屈)。

## 7. ネストした配列を CROSS APPLY OPENJSON で展開する

JSON の実務でもっとも頻出するのが **「配列の中に配列」** の展開です。
`AS JSON` で子配列を列として取り出し、それを **`CROSS APPLY OPENJSON`** でさらに展開します。
[14 APPLY](14_apply.md) で学んだ「行ごとにテーブル値関数を呼ぶ」の応用そのものです。

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

SELECT  o.OrderId,
        o.OrderDate,
        o.CustomerName,
        l.ProductId,
        p.ProductName,                                   -- サンプルDBと結合もできる
        l.Quantity,
        CAST(l.Quantity * l.UnitPrice * (1 - l.Discount) AS DECIMAL(12,2)) AS 明細金額
FROM    OPENJSON(@orders)                                -- ① 注文配列を1注文=1行に展開
        WITH (
            OrderId      INT           '$.orderId',
            OrderDate    DATE          '$.orderDate',
            CustomerId   INT           '$.customer.customerId',
            CustomerName NVARCHAR(50)  '$.customer.customerName',
            Lines        NVARCHAR(MAX) '$.lines' AS JSON  -- ② 明細配列をJSONのまま持つ
        ) AS o
        CROSS APPLY OPENJSON(o.Lines)                     -- ③ 注文ごとに明細を展開
        WITH (
            ProductId INT           '$.productId',
            Quantity  INT           '$.quantity',
            UnitPrice DECIMAL(12,2) '$.unitPrice',
            Discount  DECIMAL(5,2)  '$.discount'
        ) AS l
        LEFT JOIN dbo.Products AS p ON p.ProductId = l.ProductId
ORDER BY o.OrderId, l.ProductId;
```

ここまで表になれば、あとは **普通の T-SQL** です。集計もできます。

```sql
-- 注文ごとの合計金額(JSON をそのまま集計する)
SELECT  o.OrderId,
        o.CustomerName,
        SUM(CAST(l.Quantity * l.UnitPrice * (1 - l.Discount) AS DECIMAL(12,2))) AS 合計金額,
        COUNT(*) AS 明細件数
FROM    OPENJSON(@orders)
        WITH (
            OrderId      INT           '$.orderId',
            CustomerName NVARCHAR(50)  '$.customer.customerName',
            Lines        NVARCHAR(MAX) '$.lines' AS JSON
        ) AS o
        CROSS APPLY OPENJSON(o.Lines)
        WITH (
            Quantity  INT           '$.quantity',
            UnitPrice DECIMAL(12,2) '$.unitPrice',
            Discount  DECIMAL(5,2)  '$.discount'
        ) AS l
GROUP BY o.OrderId, o.CustomerName
ORDER BY 合計金額 DESC;
```

- **`CROSS APPLY`** は「子が0件の親を落とす」ので、明細が空配列 `[]` の注文は消えます。
  **明細が無い注文もヘッダだけ残したい** なら **`OUTER APPLY`** にします([14 APPLY](14_apply.md))。
- 3階層以上のネストでも、`AS JSON` → `CROSS APPLY OPENJSON` を繰り返すだけです。

---

# 【書く】表 → JSON

## 8. FOR JSON AUTO と FOR JSON PATH

`SELECT ... FOR JSON` を付けると、結果セットが **1つの JSON 文字列** になります。
モードは2つです。

| モード | 構造の決まり方 | 使いどころ |
|---|---|---|
| `FOR JSON AUTO` | **`FROM` 句のテーブルの順序** から自動でネストする | とりあえず JSON にしたい / 単純な構造 |
| `FOR JSON PATH` | **列の別名(ドット記法)** で自分が完全に制御する | API のレスポンスなど **形が決まっている** 場合 |

### FOR JSON AUTO

```sql
SELECT  c.CustomerId,
        c.CustomerName,
        o.OrderId,
        o.OrderDate
FROM    dbo.Customers AS c
        INNER JOIN dbo.Orders AS o ON o.CustomerId = c.CustomerId
WHERE   c.CustomerId IN (1, 2)
ORDER BY c.CustomerId, o.OrderId        -- ← AUTO では並び順が構造を決める
FOR JSON AUTO;
```

出力(整形して表示):

```json
[
  { "CustomerId": 1, "CustomerName": "アルファ商事",
    "o": [ { "OrderId": 1001, "OrderDate": "2023-01-15" },
           { "OrderId": 1004, "OrderDate": "2023-03-02" } ] },
  { "CustomerId": 2, "CustomerName": "ベータ工業",
    "o": [ { "OrderId": 1002, "OrderDate": "2023-01-20" } ] }
]
```

- **最初のテーブルが親、次のテーブルが子の配列** になります。
- **子配列のキー名はテーブル別名そのまま**(上例では `o`)。
  分かりやすい名前にしたければ `AS Orders` のように **別名を工夫**します。
- **`ORDER BY` で親ごとにまとめないと、同じ親が何度も現れます**。AUTO の最大の落とし穴です。

### FOR JSON PATH

`PATH` では **列の別名がそのまま JSON のパス** になります。
`AS [a.b]` と書けば `{"a":{"b": ... }}` の形になります。

```sql
SELECT  c.CustomerId          AS [customerId],
        c.CustomerName        AS [customerName],
        c.City                AS [address.city],       -- ← ドット記法でネスト
        c.Region              AS [address.region],
        e.LastName + e.FirstName AS [salesRep.name]
FROM    dbo.Customers AS c
        LEFT JOIN dbo.Employees AS e ON e.EmployeeId = c.SalesRepId
WHERE   c.CustomerId IN (1, 9)
ORDER BY c.CustomerId
FOR JSON PATH;
```

出力:

```json
[
  { "customerId": 1, "customerName": "アルファ商事",
    "address": { "city": "東京", "region": "関東" },
    "salesRep": { "name": "鈴木花子" } },
  { "customerId": 9, "customerName": "イオタ商会",
    "address": { "city": "仙台", "region": "東北" } }
]
```

- 顧客9は担当者が NULL なので、**`salesRep` プロパティごと出力されません**(既定の挙動)。
- **キー名を自由に決められる**ので、JavaScript 側の命名規則(camelCase)にも合わせられます。
- 迷ったら **`PATH` を使う**。`AUTO` は「手軽だが構造を制御できない」と覚えてください。

## 9. FOR JSON のオプション — ROOT / INCLUDE_NULL_VALUES / WITHOUT_ARRAY_WRAPPER

### ROOT('名前') — 全体を1つのオブジェクトで包む

```sql
SELECT  ProductId   AS [productId],
        ProductName AS [productName],
        UnitPrice   AS [unitPrice]
FROM    dbo.Products
WHERE   CategoryId = 3
ORDER BY ProductId
FOR JSON PATH, ROOT('products');
```

```json
{ "products": [ { "productId": 9, "productName": "ボールペン黒", "unitPrice": 150 }, ... ] }
```

- 既定では **裸の配列 `[...]`** が返ります。`ROOT` を付けると `{"名前": [...]}` になります。
- API のレスポンスとしては、**ルートをオブジェクトにしておくと後から項目を足しやすい**
  ため、`ROOT` を付ける設計が好まれます。

### INCLUDE_NULL_VALUES — NULL の列も出力する

`FOR JSON` は既定で **NULL の列を出力しません**(JSON を小さくするため)。
「キーは常に存在してほしい」場合は `INCLUDE_NULL_VALUES` を付けます。

```sql
-- 既定: ShipDate が NULL の注文には shipDate キーが現れない
SELECT  OrderId AS [orderId], ShipDate AS [shipDate]
FROM    dbo.Orders
WHERE   OrderId IN (1005, 1006)
FOR JSON PATH;
-- → [{"orderId":1005,"shipDate":"2023-03-15"},{"orderId":1006}]

-- INCLUDE_NULL_VALUES: null として明示的に出力される
SELECT  OrderId AS [orderId], ShipDate AS [shipDate]
FROM    dbo.Orders
WHERE   OrderId IN (1005, 1006)
FOR JSON PATH, INCLUDE_NULL_VALUES;
-- → [{"orderId":1005,"shipDate":"2023-03-15"},{"orderId":1006,"shipDate":null}]
```

> ⚠️ 受け取る側が「キーが無い」と「値が null」を区別するコードだと、ここが不具合の温床です。
> **未出荷を `null` として明示したい**なら `INCLUDE_NULL_VALUES` を付けます。

### WITHOUT_ARRAY_WRAPPER — 配列の `[ ]` を外す

1行だけ返すクエリを **単一オブジェクト** にしたいときに使います。

```sql
SELECT TOP (1)
        c.CustomerId   AS [customerId],
        c.CustomerName AS [customerName],
        c.City         AS [city]
FROM    dbo.Customers AS c
WHERE   c.CustomerId = 1
FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
-- → {"customerId":1,"customerName":"アルファ商事","city":"東京"}
```

> ⚠️ `WITHOUT_ARRAY_WRAPPER` は **複数行返っても `[ ]` を付けません**。
> 結果は `{...},{...}` という **不正な JSON** になります。
> 必ず **1行に絞れることを保証**してから使ってください(`TOP (1)` や主キー指定)。
>
> ⚠️ また、`WITHOUT_ARRAY_WRAPPER` は **`ROOT` と同時に指定できません**(エラー)。

## 10. ネストした JSON を作る — 顧客 → 注文 → 明細

`FOR JSON PATH` のドット記法は **オブジェクトのネスト** は作れますが、
**子の配列** は作れません。子配列は **相関サブクエリ + `FOR JSON PATH`** で作ります。
これが「1つの JSON に階層構造を詰める」ときの決定版パターンです。

```sql
SELECT  c.CustomerId   AS [customerId],
        c.CustomerName AS [customerName],
        c.City         AS [address.city],
        c.Region       AS [address.region],

        -- 子: 注文の配列
        (SELECT  o.OrderId   AS [orderId],
                 o.OrderDate AS [orderDate],
                 o.ShipDate  AS [shipDate],

                 -- 孫: 明細の配列
                 (SELECT  od.ProductId AS [productId],
                          p.ProductName AS [productName],
                          od.Quantity  AS [quantity],
                          od.UnitPrice AS [unitPrice],
                          CAST(od.Quantity * od.UnitPrice * (1 - od.Discount)
                               AS DECIMAL(12,2)) AS [amount]
                  FROM    dbo.OrderDetails AS od
                          INNER JOIN dbo.Products AS p ON p.ProductId = od.ProductId
                  WHERE   od.OrderId = o.OrderId
                  ORDER BY od.ProductId
                  FOR JSON PATH) AS [details]

         FROM   dbo.Orders AS o
         WHERE  o.CustomerId = c.CustomerId
         ORDER BY o.OrderId
         FOR JSON PATH) AS [orders]

FROM    dbo.Customers AS c
WHERE   c.CustomerId IN (1, 3)
ORDER BY c.CustomerId
FOR JSON PATH, ROOT('customers'), INCLUDE_NULL_VALUES;
```

出力の骨格:

```json
{
  "customers": [
    {
      "customerId": 1,
      "customerName": "アルファ商事",
      "address": { "city": "東京", "region": "関東" },
      "orders": [
        { "orderId": 1001, "orderDate": "2023-01-15", "shipDate": "2023-01-18",
          "details": [ { "productId": 1, "productName": "ノートPC",
                         "quantity": 2, "unitPrice": 128000, "amount": 230400.00 } ] },
        ...
      ]
    },
    ...
  ]
}
```

ポイント:

- **サブクエリに `FOR JSON` を付けると、SQL Server はその列を「JSON である」と認識**し、
  エスケープせずにそのまま埋め込みます。`JSON_QUERY` で包む必要はありません。
- 各階層で `ORDER BY` を書けるので、**配列の並び順を制御できます**。
- 子が0件の場合、その列は NULL になり **`orders` キーごと消えます**
  (`INCLUDE_NULL_VALUES` を付けると `"orders": null` になります)。
  「空配列 `[]` にしたい」なら `COALESCE(サブクエリ, N'[]')` を `JSON_QUERY` で包みます。

```sql
-- 子が0件でも "orders": [] を出したい場合(顧客11は注文なし)
SELECT  c.CustomerId   AS [customerId],
        c.CustomerName AS [customerName],
        JSON_QUERY(COALESCE(
            (SELECT o.OrderId AS [orderId], o.OrderDate AS [orderDate]
             FROM   dbo.Orders AS o
             WHERE  o.CustomerId = c.CustomerId
             ORDER BY o.OrderId
             FOR JSON PATH),
            N'[]')) AS [orders]
FROM    dbo.Customers AS c
WHERE   c.CustomerId IN (1, 11)
ORDER BY c.CustomerId
FOR JSON PATH, ROOT('customers');
```

> ⚠️ **SSMS の落とし穴**: `FOR JSON` の結果はグリッドでは **2033 文字ごとに分割** されて
> 複数行に見えることがあります。**壊れているわけではありません**。
> セルをクリックして全文を開くか、「結果をテキストで表示」+ 十分な最大文字数設定で確認してください。

---

# 【更新・実務】

## 11. JSON_MODIFY() で部分更新する

`JSON_MODIFY(JSON式, パス, 新しい値)` は、**更新後の JSON 文字列を返す関数** です。
元の文字列を書き換えるのではなく、**新しい文字列を返す**点に注意してください。

```sql
DECLARE @order NVARCHAR(MAX) = N'
{
  "orderId": 2001,
  "orderDate": "2024-02-01",
  "shipDate": null,
  "customer": { "customerId": 1, "customerName": "アルファ商事", "city": "東京" },
  "lines": [ { "productId": 1, "quantity": 2, "unitPrice": 128000, "discount": 0.10 } ]
}';

-- ① 既存プロパティの更新
SELECT JSON_MODIFY(@order, '$.shipDate', '2024-02-05') AS 出荷日を設定;

-- ② 存在しないプロパティの追加(lax モードでは「なければ追加」)
SELECT JSON_MODIFY(@order, '$.status', N'出荷済') AS ステータス追加;

-- ③ プロパティの削除(lax + NULL で「消える」)
SELECT JSON_MODIFY(@order, '$.customer.city', NULL) AS 市を削除;

-- ④ null をセットしたい(消したくない)場合は strict
SELECT JSON_MODIFY(@order, 'strict $.orderDate', NULL) AS 注文日をnullに;

-- ⑤ 配列への追加は append 修飾子
SELECT JSON_MODIFY(@order, 'append $.lines',
                   JSON_QUERY(N'{"productId":2,"quantity":5,"unitPrice":2800,"discount":0.00}'))
       AS 明細を1件追加;

-- ⑥ 複数の変更はネストして書く(内側から順に適用される)
SELECT JSON_MODIFY(
         JSON_MODIFY(
           JSON_MODIFY(@order, '$.shipDate', '2024-02-05'),
           '$.status', N'出荷済'),
         '$.customer.city', NULL) AS まとめて更新;
```

覚えておくべき挙動:

| やりたいこと | 書き方 |
|---|---|
| 値を更新 | `JSON_MODIFY(@j, '$.a', 新値)` |
| プロパティを追加 | 同上(lax なら無ければ追加される) |
| プロパティを **削除** | `JSON_MODIFY(@j, '$.a', NULL)`(lax) |
| 値を **null にする** | `JSON_MODIFY(@j, 'strict $.a', NULL)` |
| 配列末尾に追加 | `JSON_MODIFY(@j, 'append $.arr', 値)` |
| オブジェクト/配列を入れる | 値を **`JSON_QUERY(...)` で包む** |

> ⚠️ **文字列として埋め込まれてしまう問題**
> `JSON_MODIFY(@j, '$.customer', N'{"customerId":9}')` と書くと、
> `"customer":"{\"customerId\":9}"` のように **文字列** になってしまいます。
> オブジェクト/配列を入れるときは **必ず `JSON_QUERY()` で包む**こと。
>
> ⚠️ **数値か文字列かは渡す SQL の型で決まります**。
> `JSON_MODIFY(@j, '$.qty', '5')` は `"qty":"5"`(文字列)、
> `JSON_MODIFY(@j, '$.qty', CAST(5 AS INT))` は `"qty":5`(数値)になります。

### テーブル列の JSON を UPDATE する

実務では `UPDATE ... SET 列 = JSON_MODIFY(列, ...)` の形で使います。
サンプルDBを壊さないよう、**一時テーブル**で試します。

```sql
CREATE TABLE #ApiOrders (
    ApiOrderId INT IDENTITY(1,1) PRIMARY KEY,
    Payload    NVARCHAR(MAX) NOT NULL,
    CHECK (ISJSON(Payload) = 1)          -- ← 壊れた JSON を弾く(第12節)
);

INSERT INTO #ApiOrders (Payload)
VALUES (N'{"orderId":2001,"customer":{"customerId":1},"shipDate":null,"status":"受付"}'),
       (N'{"orderId":2002,"customer":{"customerId":3},"shipDate":null,"status":"受付"}');

-- 注文2001 を「出荷済」にして出荷日を入れる
UPDATE #ApiOrders
SET    Payload = JSON_MODIFY(
                   JSON_MODIFY(Payload, '$.status', N'出荷済'),
                   '$.shipDate', '2024-02-05')
WHERE  JSON_VALUE(Payload, '$.orderId') = N'2001';

SELECT ApiOrderId, Payload FROM #ApiOrders;

DROP TABLE #ApiOrders;                   -- 後片付け
```

## 12. JSON を NVARCHAR(MAX) 列に保存する設計と CHECK 制約

SQL Server に JSON 型は無いので、保存先は **`NVARCHAR(MAX)`** になります。
このとき **必ずセットで付けたいのが `CHECK (ISJSON(列) = 1)`** です。

```sql
BEGIN TRAN;

CREATE TABLE dbo.ApiOrderInbox (
    InboxId    INT IDENTITY(1,1) NOT NULL
        CONSTRAINT PK_ApiOrderInbox PRIMARY KEY,
    ReceivedAt DATETIME2(0)  NOT NULL
        CONSTRAINT DF_ApiOrderInbox_ReceivedAt DEFAULT (SYSDATETIME()),
    Payload    NVARCHAR(MAX) NOT NULL
        CONSTRAINT CK_ApiOrderInbox_Payload CHECK (ISJSON(Payload) = 1)
);

-- 正しい JSON は入る
INSERT INTO dbo.ApiOrderInbox (Payload) VALUES (N'{"orderId":2001}');

-- 壊れた JSON は CHECK 制約違反ではじかれる(意図的にエラーを起こす例)
BEGIN TRY
    INSERT INTO dbo.ApiOrderInbox (Payload) VALUES (N'{"orderId":2001');
END TRY
BEGIN CATCH
    SELECT ERROR_NUMBER() AS エラー番号, ERROR_MESSAGE() AS メッセージ;
END CATCH;

SELECT * FROM dbo.ApiOrderInbox;

ROLLBACK;   -- ← テーブルごと無かったことにする(サンプルDBを汚さない)
```

設計上の要点:

- **型は `NVARCHAR(MAX)`**。`VARCHAR` にすると日本語や絵文字が壊れます。
  ただし `NVARCHAR(MAX)` は LOB なので、**短いことが確実なら `NVARCHAR(4000)`** のほうが
  性能面で有利な場合があります。
- **`CHECK (ISJSON(col) = 1)`** を必ず付ける。これが無いと「JSON 列」ではなく
  「たまたま JSON が入っていることが多い文字列列」になってしまいます。
- **`NOT NULL` にするか**は要検討。NULL 許可にするなら `ISJSON` は NULL を返して
  CHECK は通る(制約は UNKNOWN を違反としない)ので、意図どおり動きます。
- JSON 列に対する **既定の検索は必ず全表スキャン** です。対策は次節。

## 13. 計算列 + インデックスで JSON 内の値を高速検索する

`WHERE JSON_VALUE(Payload, '$.customer.customerId') = ...` は、
**列の値を関数に通してから比較している**ので SARGable ではなく、
[18 インデックスと実行プラン](18_indexes_execution_plans.md) で学んだとおり
**インデックスが効きません**(必ずスキャンになります)。

解決策は **「JSON 内の値を計算列として実体化し、その計算列にインデックスを張る」** ことです。

```sql
-- 一時テーブルで試す(本番テーブルなら BEGIN TRAN ... ROLLBACK で囲む)
CREATE TABLE #ApiOrders (
    ApiOrderId INT IDENTITY(1,1) PRIMARY KEY,
    Payload    NVARCHAR(MAX) NOT NULL,
    CHECK (ISJSON(Payload) = 1)
);

-- 適当な件数を投入(1〜12 の顧客に紐づく注文を1万件)
INSERT INTO #ApiOrders (Payload)
SELECT N'{"orderId":' + CAST(n AS NVARCHAR(10))
     + N',"customer":{"customerId":' + CAST(((n - 1) % 12) + 1 AS NVARCHAR(10)) + N'}'
     + N',"status":"' + CASE WHEN n % 20 = 0 THEN N'保留' ELSE N'完了' END + N'"}'
FROM  (SELECT TOP (10000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
       FROM   sys.all_objects AS a CROSS JOIN sys.all_objects AS b) AS t;

-- ① 何もしない状態: 全行スキャン + 1万回の JSON_VALUE 評価
SET STATISTICS IO ON;
SELECT COUNT(*)
FROM   #ApiOrders
WHERE  JSON_VALUE(Payload, '$.customer.customerId') = N'7';
SET STATISTICS IO OFF;

-- ② JSON 内の値を PERSISTED 計算列として実体化する
ALTER TABLE #ApiOrders
ADD CustomerId AS CAST(JSON_VALUE(Payload, '$.customer.customerId') AS INT) PERSISTED;

-- ③ その計算列にインデックスを張る
CREATE NONCLUSTERED INDEX IX_ApiOrders_CustomerId
    ON #ApiOrders (CustomerId);

-- ④ 計算列で検索 → インデックスシークになる
SET STATISTICS IO ON;
SELECT COUNT(*)
FROM   #ApiOrders
WHERE  CustomerId = 7;
SET STATISTICS IO OFF;

-- 後片付け
DROP INDEX IX_ApiOrders_CustomerId ON #ApiOrders;
DROP TABLE #ApiOrders;
```

押さえるべき点:

- **`PERSISTED`** を付けると計算結果がディスクに実体化され、検索時に JSON を
  再パースしなくて済みます。JSON のパースは重いので、**JSON 由来の計算列は
  `PERSISTED` が基本**です。
- 計算列は **決定的(deterministic)** でなければインデックスを張れません。
  `JSON_VALUE` は決定的なので問題ありません。
- **文字列を取り出す場合はサイズを絞る**こと。
  `CAST(JSON_VALUE(Payload, '$.status') AS NVARCHAR(20))` のようにしないと、
  `NVARCHAR(4000)` はインデックスキーの上限(900 / 1700 バイト)を圧迫します。
- **オプティマイザは式のマッチングをしてくれます**。
  `PERSISTED` 計算列を作ると、`WHERE JSON_VALUE(Payload, '$.customer.customerId') = 7`
  のように **元の式で書いてもインデックスが使われることがあります**
  (型が一致していることが条件)。実行プランで必ず確認しましょう。
- 選択率が低い(=ヒット件数が少ない)検索ほど効果的です。
  「JSON 内の 1〜2 個のキーだけ頻繁に検索される」というのが典型的な適用場面です。

> ⚠️ 計算列を増やしすぎるのは本末転倒です。
> **3つも4つもインデックス付き計算列が必要になったら、それは「JSON にすべきでない
> データを JSON に入れている」サイン**です。次節へ。

## 14. リレーショナル設計と JSON 保存の使い分け(実務指針)

JSON は便利ですが、**何でも JSON にすると RDB の長所を全部捨てる**ことになります。
判断基準を持っておきましょう。

### JSON で保存してよいもの

- **スキーマが安定しない / 項目が顧客ごとに違う属性**
  (例: 商品ごとにバラバラな仕様値、アンケートの自由項目)
- **外部システムから受け取った生データの保管**
  (監査・再処理用に「届いたまま」を残す。いわゆる受信ボックス)
- **まとめて読み書きし、中身で検索しない付随情報**
  (UI の表示設定、ログの詳細ペイロード)
- **疎な属性**(列にすると NULL だらけになるもの)

### リレーショナル(通常の列/テーブル)にすべきもの

- **検索・結合・集計の対象になる項目**(顧客ID、注文日、金額、ステータス…)
- **外部キーで整合性を守りたい項目**
  → JSON の中の `customerId` に **外部キー制約は張れません**。
- **一意性・NOT NULL・CHECK など制約で守りたい項目**
- **頻繁に部分更新される項目**
  → `JSON_MODIFY` は毎回 **文字列全体を書き換えます**。大きな JSON の1項目更新は高コスト。

### 実務でよく採る折衷案

**「検索する項目は列に、残りは JSON に」** というハイブリッド設計です。

```
dbo.ApiOrderInbox
  InboxId      INT          PK
  OrderId      INT          NOT NULL   ← 検索する項目は列に昇格(インデックス可)
  CustomerId   INT          NOT NULL   ← 同上。外部キーも張れる
  ReceivedAt   DATETIME2    NOT NULL
  Payload      NVARCHAR(MAX) NOT NULL  ← 生データはそのまま保持
     CHECK (ISJSON(Payload) = 1)
```

昇格させる列は、第13節の **`PERSISTED` 計算列**にしてもよいですし、
取り込み時に `OPENJSON ... WITH` で明示的に埋めてもかまいません。
後者のほうが制約(外部キーなど)を素直に張れるので、**恒久データでは取り込み型**が
おすすめです。

```sql
-- 取り込み型: API の JSON を OPENJSON で受けて、正規化されたテーブルへ INSERT する
DECLARE @orders NVARCHAR(MAX) = N'
[
  { "orderId": 2001, "orderDate": "2024-02-01", "customer": { "customerId": 1 },
    "lines": [ { "productId": 1, "quantity": 2, "unitPrice": 128000, "discount": 0.10 } ] },
  { "orderId": 2002, "orderDate": "2024-02-03", "customer": { "customerId": 3 },
    "lines": [ { "productId": 6, "quantity": 1, "unitPrice": 32000,  "discount": 0.00 } ] }
]';

CREATE TABLE #StagingOrders (
    OrderId    INT PRIMARY KEY,
    CustomerId INT  NOT NULL,
    OrderDate  DATE NOT NULL
);
CREATE TABLE #StagingOrderDetails (
    OrderId   INT NOT NULL,
    ProductId INT NOT NULL,
    Quantity  INT NOT NULL,
    UnitPrice DECIMAL(12,2) NOT NULL,
    Discount  DECIMAL(5,2)  NOT NULL,
    PRIMARY KEY (OrderId, ProductId)
);

-- ヘッダを取り込む
INSERT INTO #StagingOrders (OrderId, CustomerId, OrderDate)
SELECT o.OrderId, o.CustomerId, o.OrderDate
FROM   OPENJSON(@orders)
       WITH (OrderId    INT  '$.orderId',
             CustomerId INT  '$.customer.customerId',
             OrderDate  DATE '$.orderDate') AS o;

-- 明細を取り込む(CROSS APPLY でネストを展開)
INSERT INTO #StagingOrderDetails (OrderId, ProductId, Quantity, UnitPrice, Discount)
SELECT o.OrderId, l.ProductId, l.Quantity, l.UnitPrice, l.Discount
FROM   OPENJSON(@orders)
       WITH (OrderId INT           '$.orderId',
             Lines   NVARCHAR(MAX) '$.lines' AS JSON) AS o
       CROSS APPLY OPENJSON(o.Lines)
       WITH (ProductId INT           '$.productId',
             Quantity  INT           '$.quantity',
             UnitPrice DECIMAL(12,2) '$.unitPrice',
             Discount  DECIMAL(5,2)  '$.discount') AS l;

SELECT * FROM #StagingOrders;
SELECT * FROM #StagingOrderDetails;

DROP TABLE #StagingOrderDetails;
DROP TABLE #StagingOrders;
```

> 📌 **一言でまとめると**
> **「JSON は "箱" として優秀、"索引" としては劣る」**。
> 検索軸になる項目は列に出し、それ以外を JSON に入れる。
> 迷ったら **まずリレーショナルで設計し、どうしても収まらないものだけ JSON にする**。

> 📌 **参考: SQL Server 2022 以降の追加機能**(2016〜2019 では使えません)
> - `ISJSON(式, 種類)` … JSON の種類まで検証
> - `JSON_PATH_EXISTS(式, パス)` … パスの存在を 1/0 で判定
> - `JSON_OBJECT(...)` / `JSON_ARRAY(...)` … JSON を組み立てるコンストラクタ関数
> - JSON 圧縮(`COMPRESS`/`DECOMPRESS` との併用は 2016 から可能)
> さらに **SQL Server 2025 / Azure SQL Database** ではネイティブの `json` データ型と
> JSON インデックスが導入されています。将来的にはそちらが本命になります。

## よくあるつまずき

- **`OPENJSON` で「オブジェクト名 'OPENJSON' が無効です」** →
  データベースの **互換性レベルが 130 未満**。`sys.databases` で確認し、必要なら
  `ALTER DATABASE ... SET COMPATIBILITY_LEVEL = 130` 以上にする。
- **`JSON_VALUE` が全部 NULL になる** → パスのキー名の綴り/大小文字違い(JSON は大小文字を区別)。
  または **オブジェクト/配列を指している**(その場合は `JSON_QUERY`)。`strict` にすると原因が分かる。
- **`JSON_QUERY` が NULL** → スカラーを指している。`JSON_VALUE` を使う。
- **日本語が `?` になる** → JSON リテラルに `N` を付け忘れ(`N'{"名前":"東京"}'`)。
- **数値の比較・並べ替えがおかしい** → `JSON_VALUE` は `NVARCHAR(4000)` を返す。
  `CAST` / `TRY_CAST` するか、`OPENJSON ... WITH` で型を指定する。
- **`AS JSON` 列でエラー** → `AS JSON` は **`NVARCHAR(MAX)` 専用**。
- **`FOR JSON AUTO` で同じ親が何度も出る** → 親の列で `ORDER BY` していない。
- **`FOR JSON` の結果が途中で切れて見える** → SSMS の 2033 文字分割表示。データは壊れていない。
- **JSON を埋め込んだら `\"` だらけ** → `JSON_QUERY()` で包み忘れ。
- **`WITHOUT_ARRAY_WRAPPER` で不正な JSON** → 複数行返っている。1行に絞る。
  また `ROOT` とは併用できない。
- **`JSON_MODIFY` でプロパティが消えた** → lax モードで `NULL` をセットした。
  null を入れたいなら `strict`。
- **JSON 列の検索が遅い** → `WHERE JSON_VALUE(...)` はインデックスが効かない。
  `PERSISTED` 計算列 + インデックス、または列への昇格を検討する。

## この章のまとめ

- JSON 関数は **SQL Server 2016 以降**。`OPENJSON` は **互換性レベル 130 以上** が必要。
  SQL Server に JSON 型は無く、**`NVARCHAR` + 関数群**で扱う。
- **読む**: `ISJSON` で検証 → **スカラーは `JSON_VALUE`、オブジェクト/配列は `JSON_QUERY`**。
  パスは `$.a.b` / `$[0]`、既定は **lax(無ければ NULL)**、`strict` はエラーで気づける。
- **表化**: `OPENJSON` の既定スキーマ(`key`/`value`/`type`)は構造調査に、
  **`WITH` 句**は実務の主役。**`AS JSON` + `CROSS APPLY OPENJSON`** でネストした配列を展開する。
- **書く**: `FOR JSON AUTO` は自動ネスト(並び順依存)、**`FOR JSON PATH` は別名のドット記法で完全制御**。
  `ROOT` / `INCLUDE_NULL_VALUES` / `WITHOUT_ARRAY_WRAPPER` を目的に応じて付ける。
  **子配列は相関サブクエリ + `FOR JSON PATH`** で埋め込む。
- **更新**: `JSON_MODIFY` は新しい文字列を返す関数。追加・更新・削除(lax+NULL)・
  `append`、オブジェクトは **`JSON_QUERY` で包む**。
- **設計**: `NVARCHAR(MAX)` + **`CHECK (ISJSON(col) = 1)`** はセット。
  検索軸は **`PERSISTED` 計算列 + インデックス**、あるいは **列に昇格**。
- **何でも JSON にしない**。検索・結合・集計・制約の対象はリレーショナルに、
  疎で不定形な属性と生データ保管を JSON に。**「JSON は箱、索引ではない」**。

➡ 演習: [exercises/22_json.md](../exercises/22_json.md)

---

これで全22トピックは修了です。おつかれさまでした！
基礎の `SELECT` から始まり、結合・集計・ウィンドウ関数・CTE を通り、
APPLY・一時テーブル・ストアドプロシージャ・TVP・インデックス・トランザクション・
動的SQL・実務パターン、そして JSON まで一周しました。

- 学習の全体像とチェックリストは [ROADMAP](../ROADMAP.md) で振り返れます。
- 各トピックの入口は [README](../README.md) のカリキュラム一覧から。

ここからは **自分の現場のテーブルで同じことをやってみる** のが最良の次の一歩です。
実行プランを開き、`SET STATISTICS IO ON` を付け、書いたクエリがなぜその速さなのかを
説明できるようになれば、もう「クエリが書ける人」です。
