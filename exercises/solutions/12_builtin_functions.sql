/* ============================================================
   解答例 12 — 組み込み関数(文字列・日付・数値・変換)
   対象演習: exercises/12_builtin_functions.md
   注意: STRING_AGG/CONCAT_WS/TRIM は 2017+、EOMONTH/STRING_SPLIT は 2016+。
         明細金額 = Quantity * UnitPrice * (1 - Discount)
   ============================================================ */
USE SalesLearning;
GO

------------------------------------------------------------
-- 基礎
------------------------------------------------------------

-- Q1. 姓名を CONCAT で連結(Email が NULL でも氏名は欠けない)
SELECT EmployeeId,
       CONCAT(LastName, N' ', FirstName) AS 氏名
FROM   dbo.Employees;

-- Q2. 文字数(LEN)とバイト長(DATALENGTH)の違い
--     NVARCHAR は 1 文字 2 バイトなので、日本語列では DATALENGTH ≒ LEN×2。
SELECT ProductName,
       LEN(ProductName)        AS 文字数,
       DATALENGTH(ProductName) AS バイト長
FROM   dbo.Products;

-- Q3. 先頭3文字と末尾2文字
SELECT ProductName,
       LEFT(ProductName, 3)  AS 先頭3文字,
       RIGHT(ProductName, 2) AS 末尾2文字
FROM   dbo.Products;

-- Q4. 「ノート」→「NOTE」に置換
SELECT ProductName,
       REPLACE(ProductName, N'ノート', N'NOTE') AS 置換後
FROM   dbo.Products;

-- Q5. 年・月・日を数値で取り出す
SELECT OrderId, OrderDate,
       YEAR(OrderDate)  AS 年,
       MONTH(OrderDate) AS 月,
       DAY(OrderDate)   AS 日
FROM   dbo.Orders;

-- Q6. カンマ区切り(小数0桁)に整形。戻り値は文字列(表示専用)。
SELECT ProductName,
       FORMAT(UnitPrice, N'N0') AS 単価_カンマ区切り
FROM   dbo.Products;

------------------------------------------------------------
-- 応用
------------------------------------------------------------

-- Q7. Email のドメイン部分(@ の後ろ)を抽出。NULL の社員は除外。
SELECT EmployeeId, Email,
       SUBSTRING(Email, CHARINDEX(N'@', Email) + 1, LEN(Email)) AS ドメイン
FROM   dbo.Employees
WHERE  Email IS NOT NULL;

-- Q8. 出荷までの日数。未出荷(ShipDate NULL)は結果も NULL になる。
SELECT OrderId, OrderDate, ShipDate,
       DATEDIFF(DAY, OrderDate, ShipDate) AS 出荷までの日数
FROM   dbo.Orders;

-- Q9. 勤続年数(満年数)。応当日をまだ迎えていなければ 1 を引く。
SELECT EmployeeId,
       CONCAT(LastName, N' ', FirstName) AS 氏名,
       HireDate,
       DATEDIFF(YEAR, HireDate, GETDATE())
         - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, HireDate, GETDATE()), HireDate) > GETDATE()
                THEN 1 ELSE 0 END AS 勤続年数
FROM   dbo.Employees;

-- Q10. 月初(DATEFROMPARTS で日=1)と月末(EOMONTH, 2016+)
SELECT OrderId, OrderDate,
       DATEFROMPARTS(YEAR(OrderDate), MONTH(OrderDate), 1) AS 月初,
       EOMONTH(OrderDate)                                  AS 月末
FROM   dbo.Orders;

-- Q11. 明細金額を整数に四捨五入
SELECT OrderId, ProductId,
       ROUND(Quantity * UnitPrice * (1 - Discount), 0) AS 明細金額_丸め
FROM   dbo.OrderDetails;

-- Q12. OrderDate を yyyy/mm/dd 文字列に(CONVERT スタイル 111)
SELECT OrderId, OrderDate,
       CONVERT(VARCHAR(10), OrderDate, 111) AS 日付_スラッシュ
FROM   dbo.Orders;

------------------------------------------------------------
-- チャレンジ
------------------------------------------------------------

-- Q13. (2017+) 顧客ごとの購入商品一覧をカンマ区切りでまとめる
SELECT c.CustomerName,
       STRING_AGG(p.ProductName, N', ')
         WITHIN GROUP (ORDER BY p.ProductName) AS 購入商品一覧
FROM   dbo.Customers    AS c
JOIN   dbo.Orders       AS o  ON o.CustomerId = c.CustomerId
JOIN   dbo.OrderDetails AS od ON od.OrderId   = o.OrderId
JOIN   dbo.Products     AS p  ON p.ProductId  = od.ProductId
GROUP  BY c.CustomerName;

-- Q14. TRY_CAST でカンマ有無の違いを見る
--     '480000' は INT に変換できるが、'480,000' はカンマが数値として
--     解釈できないため TRY_CAST は NULL を返す(TRY_ 系はエラーにせず NULL)。
--     カンマを REPLACE で除去すれば変換できる。
SELECT TRY_CAST(N'480000'  AS INT)                    AS カンマなし,   -- 480000
       TRY_CAST(N'480,000' AS INT)                    AS カンマあり,   -- NULL
       TRY_CAST(REPLACE(N'480,000', N',', N'') AS INT) AS カンマ除去後; -- 480000

-- Q15. 1行の説明文字列を組み立てる
--      ドメインは Email が NULL のとき N'(なし)' を表示。
SELECT EmployeeId,
       CONCAT(
           CONCAT(LastName, N' ', FirstName),
           N' / 入社: ', CONVERT(VARCHAR(10), HireDate, 23),
           N' / 勤続 ',
           DATEDIFF(YEAR, HireDate, GETDATE())
             - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, HireDate, GETDATE()), HireDate) > GETDATE()
                    THEN 1 ELSE 0 END,
           N' 年 / ドメイン: ',
           CASE WHEN Email IS NULL THEN N'(なし)'
                ELSE SUBSTRING(Email, CHARINDEX(N'@', Email) + 1, LEN(Email))
           END
       ) AS 説明
FROM   dbo.Employees;

-- (別解 Q15) CONCAT_WS(2017+) で区切りをまとめる書き方も可
--   ただし各項目の「ラベル」を付けたい場合は上記のように CONCAT が素直。
