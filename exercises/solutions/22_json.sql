/* ============================================================
   解答例 22 — JSON操作
   対象演習: exercises/22_json.md

   バージョン前提:
     ・JSON 関数 (ISJSON / JSON_VALUE / JSON_QUERY / OPENJSON /
       JSON_MODIFY / FOR JSON) は SQL Server 2016 (13.x) 以降。
     ・OPENJSON はデータベースの互換性レベル 130 以上が必要。

   後片付けの方針:
     ・テーブルを作る問題 (Q11 / Q12) は一時テーブルを使い、
       最後に DROP INDEX / DROP TABLE まで実行する。
   ============================================================ */
USE SalesLearning;
GO

-- 実行前チェック(2016 以降 / 互換性レベル 130 以上であること)
SELECT @@VERSION AS サーバーバージョン;
SELECT name, compatibility_level AS 互換性レベル
FROM   sys.databases
WHERE  name = N'SalesLearning';
GO

------------------------------------------------------------
-- 基礎
------------------------------------------------------------

-- Q1. ISJSON で4つの文字列の妥当性を確認する
--     ・正しいオブジェクト / 配列 → 1
--     ・構文が壊れている / ただの文字列 → 0
--     ・入力が NULL → NULL(0 ではない点に注意)
SELECT ISJSON(N'{"orderId": 2001}')          AS オブジェクト,   -- 1
       ISJSON(N'[1, 2, 3]')                  AS 配列,           -- 1
       ISJSON(N'{"orderId": 2001')           AS 壊れたJSON,     -- 0
       ISJSON(CAST(NULL AS NVARCHAR(MAX)))   AS NULL入力;       -- NULL
GO

-- Q2. JSON_VALUE でスカラー値を取り出す(型変換つき)
--     JSON_VALUE の戻り値は常に NVARCHAR(4000) なので、
--     数値・日付として使うなら CAST が必須。
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

SELECT CAST(JSON_VALUE(@order, '$.orderId')   AS INT)  AS 注文番号,
       CAST(JSON_VALUE(@order, '$.orderDate') AS DATE) AS 注文日,
       JSON_VALUE(@order, '$.customer.customerName')   AS 顧客名,
       JSON_VALUE(@order, '$.lines[0].productName')    AS 明細1商品名;

-- (別解) 型が保証できない外部データなら TRY_CAST でエラーを避ける
SELECT TRY_CAST(JSON_VALUE(@order, '$.orderId')   AS INT)  AS 注文番号,
       TRY_CAST(JSON_VALUE(@order, '$.orderDate') AS DATE) AS 注文日;
GO

-- Q3. JSON_VALUE と JSON_QUERY の違い
--     ・JSON_VALUE … スカラー(文字列/数値/true・false/null)専用
--     ・JSON_QUERY … オブジェクト {} / 配列 [] 専用
--     lax(既定)では「対象外を指定 = NULL」になる。
DECLARE @order NVARCHAR(MAX) = N'
{
  "orderId": 2001,
  "customer": { "customerId": 1, "customerName": "アルファ商事", "city": "東京" },
  "lines": [ { "productId": 1, "quantity": 2 } ]
}';

SELECT JSON_VALUE(@order, '$.customer') AS 顧客_VALUE,   -- NULL(オブジェクトなので取れない)
       JSON_QUERY(@order, '$.customer') AS 顧客_QUERY,   -- {"customerId":1,...}
       JSON_VALUE(@order, '$.orderId')  AS 注文番号_VALUE, -- 2001
       JSON_QUERY(@order, '$.orderId')  AS 注文番号_QUERY; -- NULL(スカラーなので取れない)

-- strict にすると「静かな NULL」ではなくエラーになる。
-- 必須項目の読み取りでは strict のほうが不具合に早く気づける。
BEGIN TRY
    SELECT JSON_VALUE(@order, 'strict $.customer') AS これはエラーになる;
END TRY
BEGIN CATCH
    SELECT N'strict + JSON_VALUE + オブジェクト' AS ケース,
           ERROR_NUMBER() AS エラー番号, ERROR_MESSAGE() AS メッセージ;
END CATCH;

BEGIN TRY
    SELECT JSON_VALUE(@order, 'strict $.notExists') AS これもエラーになる;
END TRY
BEGIN CATCH
    SELECT N'strict + 存在しないパス' AS ケース,
           ERROR_NUMBER() AS エラー番号, ERROR_MESSAGE() AS メッセージ;
END CATCH;

-- lax(既定)なら存在しないパスは静かに NULL
SELECT JSON_VALUE(@order, '$.notExists')     AS lax省略,
       JSON_VALUE(@order, 'lax $.notExists') AS lax明示;
GO

-- Q4. OPENJSON の既定スキーマ(key / value / type)
--     type: 0=null, 1=文字列, 2=数値, 3=true/false, 4=配列, 5=オブジェクト
--     key / value / type は予約語なので [ ] で囲む。
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

-- 最上位のプロパティ一覧(オブジェクトなので key = プロパティ名)
SELECT [key] AS プロパティ名,
       [value] AS 値,
       [type]  AS 型コード,
       CASE [type] WHEN 0 THEN N'null'
                   WHEN 1 THEN N'文字列'
                   WHEN 2 THEN N'数値'
                   WHEN 3 THEN N'true/false'
                   WHEN 4 THEN N'配列'
                   WHEN 5 THEN N'オブジェクト'
       END AS 型の意味
FROM   OPENJSON(@order);

-- $.lines を起点にすると配列なので key = 0 始まりの添字、
-- value は各要素の JSON テキスト、type = 5(オブジェクト)になる。
SELECT [key] AS 添字, [value] AS 要素JSON, [type] AS 型コード
FROM   OPENJSON(@order, '$.lines');
GO

-- Q5. OPENJSON ... WITH で明細配列を表に展開し、明細金額を計算する
--     WITH を使えば型変換は OPENJSON がやってくれるので CAST の山にならない。
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

SELECT  l.ProductId,
        l.ProductName,
        l.Quantity,
        l.UnitPrice,
        l.Discount,
        CAST(l.Quantity * l.UnitPrice * (1 - l.Discount) AS DECIMAL(12,2)) AS 明細金額
FROM    OPENJSON(@order, '$.lines')
        WITH (
            ProductId   INT           '$.productId',
            ProductName NVARCHAR(100) '$.productName',
            Quantity    INT           '$.quantity',
            UnitPrice   DECIMAL(12,2) '$.unitPrice',
            Discount    DECIMAL(5,2)  '$.discount'
        ) AS l
ORDER BY l.ProductId;

-- (参考) ヘッダの値を一緒に付ける場合は JSON_VALUE を併用する
SELECT  CAST(JSON_VALUE(@order, '$.orderId') AS INT) AS OrderId,
        JSON_VALUE(@order, '$.customer.customerName') AS CustomerName,
        l.ProductId, l.Quantity
FROM    OPENJSON(@order, '$.lines')
        WITH (ProductId INT '$.productId', Quantity INT '$.quantity') AS l
ORDER BY l.ProductId;
GO

------------------------------------------------------------
-- 応用
------------------------------------------------------------

-- Q6. ネストした配列を AS JSON + CROSS APPLY OPENJSON で展開する
--     ポイント: 子配列は NVARCHAR(MAX) ... AS JSON で受ける(型は MAX 必須)。
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

-- (1) 注文 × 明細に展開 + サンプルDBの Products と結合
SELECT  o.OrderId,
        o.OrderDate,
        o.CustomerName,
        l.ProductId,
        p.ProductName,
        l.Quantity,
        CAST(l.Quantity * l.UnitPrice * (1 - l.Discount) AS DECIMAL(12,2)) AS 明細金額
FROM    OPENJSON(@orders)
        WITH (
            OrderId      INT           '$.orderId',
            OrderDate    DATE          '$.orderDate',
            CustomerId   INT           '$.customer.customerId',
            CustomerName NVARCHAR(50)  '$.customer.customerName',
            Lines        NVARCHAR(MAX) '$.lines' AS JSON
        ) AS o
        CROSS APPLY OPENJSON(o.Lines)
        WITH (
            ProductId INT           '$.productId',
            Quantity  INT           '$.quantity',
            UnitPrice DECIMAL(12,2) '$.unitPrice',
            Discount  DECIMAL(5,2)  '$.discount'
        ) AS l
        LEFT JOIN dbo.Products AS p ON p.ProductId = l.ProductId
ORDER BY o.OrderId, l.ProductId;

-- (2) 表になってしまえば普通の GROUP BY が使える
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

-- (補足) 明細が空配列 [] の注文もヘッダを残したいなら OUTER APPLY にする(14章)。
GO

-- Q7. FOR JSON PATH でネストしたオブジェクトを作る
--     別名のドット記法 [address.city] がそのまま JSON のパスになる。
--     顧客9は SalesRepId が NULL なので、既定では "salesRep" キーごと出力されない。
SELECT  c.CustomerId                     AS [customerId],
        c.CustomerName                   AS [customerName],
        c.City                           AS [address.city],
        c.Region                         AS [address.region],
        e.EmployeeId                     AS [salesRep.employeeId],
        e.LastName + e.FirstName         AS [salesRep.name]
FROM    dbo.Customers AS c
        LEFT JOIN dbo.Employees AS e ON e.EmployeeId = c.SalesRepId
WHERE   c.CustomerId IN (1, 3, 9)
ORDER BY c.CustomerId
FOR JSON PATH, ROOT('customers');

-- (参考) INCLUDE_NULL_VALUES を付けると
--        "salesRep": { "employeeId": null, "name": null } が出力される。
SELECT  c.CustomerId                     AS [customerId],
        c.CustomerName                   AS [customerName],
        c.City                           AS [address.city],
        c.Region                         AS [address.region],
        e.EmployeeId                     AS [salesRep.employeeId],
        e.LastName + e.FirstName         AS [salesRep.name]
FROM    dbo.Customers AS c
        LEFT JOIN dbo.Employees AS e ON e.EmployeeId = c.SalesRepId
WHERE   c.CustomerId IN (1, 3, 9)
ORDER BY c.CustomerId
FOR JSON PATH, ROOT('customers'), INCLUDE_NULL_VALUES;
GO

-- Q8-1. FOR JSON AUTO — 構造は FROM 句のテーブル順序と行の並び順で決まる
--       ORDER BY で親ごとにまとめないと、同じ親が複数回現れてしまう。

-- ORDER BY あり(正しくネストされる)
SELECT  c.CustomerId,
        c.CustomerName,
        o.OrderId,
        o.OrderDate
FROM    dbo.Customers AS c
        INNER JOIN dbo.Orders AS o ON o.CustomerId = c.CustomerId
WHERE   c.CustomerId IN (1, 2)
ORDER BY c.CustomerId, o.OrderId
FOR JSON AUTO;

-- ORDER BY なし(並び順が保証されず、同じ顧客のオブジェクトが分裂しうる)
SELECT  c.CustomerId,
        c.CustomerName,
        o.OrderId,
        o.OrderDate
FROM    dbo.Customers AS c
        INNER JOIN dbo.Orders AS o ON o.CustomerId = c.CustomerId
WHERE   c.CustomerId IN (1, 2)
FOR JSON AUTO;

-- 同じ内容を PATH で書けば、キー名も構造も自分で決められる(実務ではこちらが基本)
SELECT  c.CustomerId   AS [customerId],
        c.CustomerName AS [customerName],
        o.OrderId      AS [order.orderId],
        o.OrderDate    AS [order.orderDate]
FROM    dbo.Customers AS c
        INNER JOIN dbo.Orders AS o ON o.CustomerId = c.CustomerId
WHERE   c.CustomerId IN (1, 2)
ORDER BY c.CustomerId, o.OrderId
FOR JSON PATH;
GO

-- Q8-2. INCLUDE_NULL_VALUES — 既定では NULL 列はキーごと出力されない
--       1006 は ShipDate = NULL(未出荷)。
SELECT  OrderId  AS [orderId],
        ShipDate AS [shipDate]
FROM    dbo.Orders
WHERE   OrderId IN (1005, 1006)
ORDER BY OrderId
FOR JSON PATH;
-- → [{"orderId":1005,"shipDate":"..."},{"orderId":1006}]   ← shipDate キーが無い

SELECT  OrderId  AS [orderId],
        ShipDate AS [shipDate]
FROM    dbo.Orders
WHERE   OrderId IN (1005, 1006)
ORDER BY OrderId
FOR JSON PATH, INCLUDE_NULL_VALUES;
-- → [{"orderId":1005,"shipDate":"..."},{"orderId":1006,"shipDate":null}]
GO

-- Q8-3. WITHOUT_ARRAY_WRAPPER — 1行だけを単一オブジェクトにする
SELECT TOP (1)
        c.CustomerId   AS [customerId],
        c.CustomerName AS [customerName],
        c.City         AS [city]
FROM    dbo.Customers AS c
WHERE   c.CustomerId = 1
FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
-- → {"customerId":1,"customerName":"アルファ商事","city":"東京"}

-- 危険な例: 複数行返るクエリに付けると [ ] が付かないまま複数オブジェクトが
--           カンマで並び、"不正な JSON" になる。受け取り側でパースエラーになる。
SELECT  c.CustomerId   AS [customerId],
        c.CustomerName AS [customerName]
FROM    dbo.Customers AS c
WHERE   c.Region = N'関東'
ORDER BY c.CustomerId
FOR JSON PATH, WITHOUT_ARRAY_WRAPPER;
-- → {...},{...},{...}   ← ISJSON で確かめると 0 になる

-- 検証: 上の結果が JSON として妥当かどうか
SELECT ISJSON(
         (SELECT c.CustomerId AS [customerId], c.CustomerName AS [customerName]
          FROM   dbo.Customers AS c
          WHERE  c.Region = N'関東'
          FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
       ) AS 複数行_WITHOUT_ARRAY_WRAPPERは妥当か;   -- 0

-- なお WITHOUT_ARRAY_WRAPPER と ROOT は同時に指定できない(エラーになる)。
GO

-- Q9. JSON_MODIFY による部分更新
--     JSON_MODIFY は「更新後の文字列を返す関数」であり、元の変数は変わらない。
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

-- (1) 既存プロパティの更新
SELECT JSON_MODIFY(@order, '$.shipDate', '2024-02-05') AS Q9_1_出荷日を更新;

-- (2) 存在しないプロパティの追加(lax モードは「無ければ追加」)
SELECT JSON_MODIFY(@order, '$.status', N'出荷済') AS Q9_2_ステータス追加;

-- (3) プロパティの削除(lax + NULL は「消す」)
SELECT JSON_MODIFY(@order, '$.customer.city', NULL) AS Q9_3_市を削除;

-- (4) null をセットする(消さない)には strict を指定する
SELECT JSON_MODIFY(@order, 'strict $.orderDate', NULL) AS Q9_4_注文日をnullに;

-- (5) 配列末尾への追加は append 修飾子。
--     オブジェクトは JSON_QUERY で包まないと文字列としてエスケープされてしまう。
SELECT JSON_MODIFY(@order, 'append $.lines',
                   JSON_QUERY(N'{"productId":10,"quantity":12,"unitPrice":280,"discount":0.00}'))
       AS Q9_5_明細を追加;

-- (誤り例) JSON_QUERY で包まないと "lines":[..., "{\"productId\":10,...}"] になる
SELECT JSON_MODIFY(@order, 'append $.lines',
                   N'{"productId":10,"quantity":12,"unitPrice":280,"discount":0.00}')
       AS Q9_5_誤り_文字列として追加される;

-- (まとめて適用) 内側から順に評価される
SELECT JSON_MODIFY(
         JSON_MODIFY(
           JSON_MODIFY(@order, '$.shipDate', '2024-02-05'),
           '$.status', N'出荷済'),
         '$.customer.city', NULL) AS Q9_まとめて更新;

-- (補足) 数値として書き込みたいときは SQL 側の型を数値にする
SELECT JSON_MODIFY(@order, '$.quantityTotal', '10')            AS 文字列になる,   -- "10"
       JSON_MODIFY(@order, '$.quantityTotal', CAST(10 AS INT)) AS 数値になる;     -- 10
GO

------------------------------------------------------------
-- チャレンジ
------------------------------------------------------------

-- Q10. 顧客 → 注文 → 明細 の3階層 JSON
--      ・オブジェクトのネストは PATH のドット記法
--      ・配列のネストは「相関サブクエリ + FOR JSON PATH」
--      ・顧客11(注文なし)でも "orders": [] にするため
--        COALESCE(..., N'[]') を JSON_QUERY で包む
SELECT  c.CustomerId   AS [customerId],
        c.CustomerName AS [customerName],
        c.City         AS [address.city],
        c.Region       AS [address.region],

        JSON_QUERY(COALESCE(
            (SELECT  o.OrderId   AS [orderId],
                     o.OrderDate AS [orderDate],
                     o.ShipDate  AS [shipDate],
                     (SELECT SUM(CAST(od2.Quantity * od2.UnitPrice * (1 - od2.Discount)
                                      AS DECIMAL(12,2)))
                      FROM   dbo.OrderDetails AS od2
                      WHERE  od2.OrderId = o.OrderId)          AS [totalAmount],

                     -- 孫: 明細の配列
                     (SELECT  od.ProductId  AS [productId],
                              p.ProductName AS [productName],
                              od.Quantity   AS [quantity],
                              od.UnitPrice  AS [unitPrice],
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
             FOR JSON PATH),
            N'[]')) AS [orders]

FROM    dbo.Customers AS c
WHERE   c.CustomerId IN (1, 3, 11)
ORDER BY c.CustomerId
FOR JSON PATH, ROOT('customers'), INCLUDE_NULL_VALUES;

-- ポイント:
--  ・サブクエリに FOR JSON を付けると、SQL Server はその列を「JSON である」と
--    認識して、エスケープせずに埋め込む(JSON_QUERY で包む必要はない)。
--    ただし COALESCE を挟むと "ただの文字列" 扱いに戻るため、
--    上のように JSON_QUERY() で包み直す必要がある。
--  ・SSMS のグリッドでは 2033 文字ごとに分割表示される。壊れているわけではない。
GO

-- Q11. JSON 列 + CHECK 制約 + PERSISTED 計算列 + インデックス
--      (一時テーブルで実験し、最後に必ず後片付けする)

-- 1. JSON 列を持つ一時テーブル。CHECK (ISJSON(col) = 1) は必ずセットで付ける。
--    ※ 一時テーブルでは制約に名前を付けない(tempdb 内で名前が衝突しうるため)。
CREATE TABLE #ApiOrders (
    ApiOrderId INT IDENTITY(1,1) PRIMARY KEY,
    Payload    NVARCHAR(MAX) NOT NULL,
    CHECK (ISJSON(Payload) = 1)
);

-- 2. 1万件の JSON を投入(customerId は 1〜12 を巡回、20件に1件を「保留」に)
INSERT INTO #ApiOrders (Payload)
SELECT N'{"orderId":' + CAST(t.n AS NVARCHAR(10))
     + N',"customer":{"customerId":' + CAST(((t.n - 1) % 12) + 1 AS NVARCHAR(10)) + N'}'
     + N',"status":"' + CASE WHEN t.n % 20 = 0 THEN N'保留' ELSE N'完了' END + N'"}'
FROM  (SELECT TOP (10000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS n
       FROM   sys.all_objects AS a
              CROSS JOIN sys.all_objects AS b) AS t;

SELECT COUNT(*) AS 投入件数 FROM #ApiOrders;

-- 3. 壊れた JSON は CHECK 制約で弾かれる
BEGIN TRY
    INSERT INTO #ApiOrders (Payload) VALUES (N'{"orderId":99999');
END TRY
BEGIN CATCH
    SELECT N'壊れた JSON の INSERT' AS ケース,
           ERROR_NUMBER() AS エラー番号, ERROR_MESSAGE() AS メッセージ;
END CATCH;

-- 4. 計算列が無い状態 → JSON_VALUE(列, ...) は SARGable でないため必ずスキャン。
--    実行プランで「Clustered Index Scan」になることを確認する。
SET STATISTICS IO ON;
SELECT COUNT(*) AS 顧客7の件数_スキャン
FROM   #ApiOrders
WHERE  JSON_VALUE(Payload, '$.customer.customerId') = N'7';
SET STATISTICS IO OFF;

-- 5. JSON 内の値を PERSISTED 計算列として実体化し、インデックスを張る
ALTER TABLE #ApiOrders
ADD CustomerId AS CAST(JSON_VALUE(Payload, '$.customer.customerId') AS INT) PERSISTED;

ALTER TABLE #ApiOrders
ADD OrderStatus AS CAST(JSON_VALUE(Payload, '$.status') AS NVARCHAR(10)) PERSISTED;
--   ↑ 文字列はサイズを絞ること。NVARCHAR(4000) のままだとインデックスキーを圧迫する。

CREATE NONCLUSTERED INDEX IX_ApiOrders_CustomerId
    ON #ApiOrders (CustomerId);

-- 6. 計算列で検索 → Index Seek になる
SET STATISTICS IO ON;
SELECT COUNT(*) AS 顧客7の件数_シーク
FROM   #ApiOrders
WHERE  CustomerId = 7;
SET STATISTICS IO OFF;

-- (参考) PERSISTED 計算列があると、元の式で書いてもオプティマイザが
--        式をマッチさせてインデックスを使えることがある。実行プランで確認する。
SET STATISTICS IO ON;
SELECT COUNT(*) AS 元の式で検索
FROM   #ApiOrders
WHERE  CAST(JSON_VALUE(Payload, '$.customer.customerId') AS INT) = 7;
SET STATISTICS IO OFF;

-- 理由:
--  4 … WHERE の左辺が「列を関数に通した式」なので、行ごとに JSON をパースして
--       評価するしかない → インデックスは使えず全行スキャン(18章の SARGability)。
--  6 … 値が計算列として実体化され、その列にインデックスがあるので
--       B木を辿って該当行だけを取り出せる(Index Seek)。

-- 7. 後片付け
DROP INDEX IX_ApiOrders_CustomerId ON #ApiOrders;
DROP TABLE #ApiOrders;
GO

-- Q12. API の JSON を正規化された一時テーブルへ取り込む(ステージング)
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

-- 1. 受け皿となる一時テーブル(制約付き = ここが「JSON のままにしない」利点)
CREATE TABLE #StagingOrders (
    OrderId    INT  NOT NULL PRIMARY KEY,
    CustomerId INT  NOT NULL,
    OrderDate  DATE NOT NULL
);

CREATE TABLE #StagingOrderDetails (
    OrderId   INT           NOT NULL,
    ProductId INT           NOT NULL,
    Quantity  INT           NOT NULL,
    UnitPrice DECIMAL(12,2) NOT NULL,
    Discount  DECIMAL(5,2)  NOT NULL,
    PRIMARY KEY (OrderId, ProductId)
);

-- 2. ヘッダの取り込み
INSERT INTO #StagingOrders (OrderId, CustomerId, OrderDate)
SELECT o.OrderId, o.CustomerId, o.OrderDate
FROM   OPENJSON(@orders)
       WITH (OrderId    INT  '$.orderId',
             CustomerId INT  '$.customer.customerId',
             OrderDate  DATE '$.orderDate') AS o;

-- 3. 明細の取り込み(AS JSON + CROSS APPLY OPENJSON)
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

-- 4. 取り込み結果をサンプルDBと結合して確認する
SELECT  so.OrderId,
        so.OrderDate,
        c.CustomerName,
        sd.ProductId,
        p.ProductName,
        sd.Quantity,
        CAST(sd.Quantity * sd.UnitPrice * (1 - sd.Discount) AS DECIMAL(12,2)) AS 明細金額
FROM    #StagingOrders AS so
        INNER JOIN #StagingOrderDetails AS sd ON sd.OrderId = so.OrderId
        LEFT  JOIN dbo.Customers AS c ON c.CustomerId = so.CustomerId
        LEFT  JOIN dbo.Products  AS p ON p.ProductId  = sd.ProductId
ORDER BY so.OrderId, sd.ProductId;

-- 5. 参照整合性の検証(実在しない顧客ID / 商品ID を洗い出す)
SELECT so.OrderId, so.CustomerId AS 実在しない顧客ID
FROM   #StagingOrders AS so
WHERE  NOT EXISTS (SELECT 1 FROM dbo.Customers AS c WHERE c.CustomerId = so.CustomerId);

SELECT DISTINCT sd.ProductId AS 実在しない商品ID
FROM   #StagingOrderDetails AS sd
WHERE  NOT EXISTS (SELECT 1 FROM dbo.Products AS p WHERE p.ProductId = sd.ProductId);
-- → 今回のデータではどちらも 0 件(すべて実在する)。

-- 6. 後片付け
DROP TABLE #StagingOrderDetails;
DROP TABLE #StagingOrders;
GO

/* ------------------------------------------------------------
   Q12 の説明: なぜ JSON のまま置かず、検索軸を列に取り出すのか

   ・外部キー
       JSON の中の "customerId" には FOREIGN KEY を張れない。
       列に取り出して初めて「存在しない顧客の注文」をDB側で防げる。
       JSON のままだと、上の 5 のような検証クエリを毎回自前で書く必要がある。

   ・インデックス
       WHERE JSON_VALUE(Payload, '$...') = ... は SARGable でないため
       常に全行スキャンになる。列(または PERSISTED 計算列 + インデックス)に
       すれば Index Seek になる。検索軸が増えるほど差は決定的になる。

   ・部分更新
       JSON_MODIFY は「新しい文字列を作って列全体を書き換える」処理。
       大きな JSON の1項目を更新するだけでも列全体の書き込みが発生し、
       ログ量も増える。普通の列なら該当列だけの更新で済む。

   結論: 検索・結合・集計・制約の対象になる項目はリレーショナルに、
         疎で不定形な属性や「届いたままの生データ」は JSON に。
         迷ったらまずリレーショナルで設計し、収まらないものだけ JSON にする。
   ------------------------------------------------------------ */
