# 12 組み込み関数(文字列・日付・数値・変換)

> **このトピックのゴール**: T-SQL に用意された **組み込みスカラー関数** を使って、
> 文字列の整形・抽出、日付の計算、数値の丸め、型変換ができるようになる。
> 特に **NULL の扱い**、**バージョン依存機能(2016/2017+)**、**FORMAT の性能** に注意する。
>
> **前提**: [11 条件式と NULL 処理](11_conditional_null.md) を済ませ、`CASE`・`ISNULL`・
> `COALESCE` と NULL の三値論理を理解していること。

すべての例は先頭で `USE SalesLearning;` を実行済みとします。

組み込み関数は「1 行につき 1 値を返す **スカラー関数**」です(`SUM` などの集計関数は別章)。
`SELECT` の式・`WHERE`・`ORDER BY` など、式が書ける場所ならどこでも使えます。

---

## 1. 文字列関数の基本(長さ・大文字小文字・トリム)

```sql
SELECT ProductName,
       LEN(ProductName)        AS 文字数,
       DATALENGTH(ProductName) AS バイト長,
       UPPER(ProductName)      AS 大文字,
       LOWER(ProductName)      AS 小文字
FROM   dbo.Products;
```

- `LEN` … **文字数** を返す。**末尾の半角スペースは数えない**点に注意。
- `DATALENGTH` … **バイト数** を返す。`NVARCHAR` は 1 文字 2 バイトなので、
  日本語列では `LEN` の 2 倍前後になる。「実データのバイトサイズ」を見たいとき用。
- `UPPER` / `LOWER` … 英字の大文字・小文字化(日本語には影響しない)。

前後の空白を除去するトリム系。

```sql
SELECT LTRIM(N'  阿部  ') AS 左だけ,
       RTRIM(N'  阿部  ') AS 右だけ,
       TRIM(N'  阿部  ')  AS 両端;      -- TRIM は SQL Server 2017+
```

> ⚠️ `TRIM`(両端を一度に除去)は **SQL Server 2017 以降**。2016 では
> `LTRIM(RTRIM(x))` と入れ子にする。`LEN` が末尾スペースを無視するのに対し、
> `DATALENGTH` はスペースも数えるので、トリム漏れの検出に使える。

## 2. 部分文字列の取り出し(LEFT / RIGHT / SUBSTRING)

```sql
SELECT ProductName,
       LEFT(ProductName, 3)         AS 先頭3文字,
       RIGHT(ProductName, 2)        AS 末尾2文字,
       SUBSTRING(ProductName, 2, 3) AS 2文字目から3文字
FROM   dbo.Products;
```

- `LEFT(文字列, n)` / `RIGHT(文字列, n)` … 左端・右端から n 文字。
- `SUBSTRING(文字列, 開始位置, 長さ)` … **開始位置は 1 始まり**。
  長さが残り文字数を超えても、そこにある分だけ返す(エラーにならない)。

## 3. 文字列の検索と置換(CHARINDEX / REPLACE)

```sql
-- 「モ」が何文字目に現れるか(見つからなければ 0)
SELECT ProductName,
       CHARINDEX(N'モ', ProductName) AS モの位置
FROM   dbo.Products;

-- 置換
SELECT REPLACE(ProductName, N'ノート', N'NOTE') AS 置換後
FROM   dbo.Products;
```

- `CHARINDEX(探す文字列, 対象[, 開始位置])` … 見つかった **1 始まりの位置**、
  見つからなければ **0** を返す。
- `REPLACE(対象, 検索, 置換)` … 一致箇所を **すべて** 置き換える。

### 応用: メールアドレスからドメインを抽出

`CHARINDEX` で `@` の位置を求め、`SUBSTRING` でその後ろを切り出す典型パターン。

```sql
SELECT Email,
       SUBSTRING(Email, CHARINDEX(N'@', Email) + 1, LEN(Email)) AS ドメイン
FROM   dbo.Employees
WHERE  Email IS NOT NULL;      -- 社員8(中村)は Email が NULL
```

- `CHARINDEX(N'@', Email) + 1` … `@` の **次の位置** から取り出す。
- 長さは `LEN(Email)`(残り全部で十分。多めに指定しても安全)。

> ⚠️ `Email` が NULL の行では結果も NULL になる。上のように `WHERE ... IS NOT NULL`
> で除くか、`WHERE CHARINDEX(N'@', Email) > 0` で `@` を含む行だけに絞ると安全。

## 4. 連結(+ / CONCAT / CONCAT_WS)と繰り返し(REPLICATE)

```sql
SELECT LastName, FirstName, Email,
       LastName + N' ' + FirstName                    AS 氏名_プラス,
       CONCAT(LastName, N' ', FirstName)              AS 氏名_CONCAT,
       CONCAT_WS(N' / ', LastName, FirstName, Email)  AS 区切り連結   -- 2017+
FROM   dbo.Employees;
```

- `+` … 文字列連結。**片方が NULL なら結果全体が NULL**([01](01_select_basics.md) 参照)。
- `CONCAT(...)` … 引数の **NULL を空文字として扱う**。数値も自動で文字列化。
- `CONCAT_WS(区切り, ...)`(**2017+**)… 第 1 引数を区切り文字にして連結。
  **NULL の引数はスキップ**され、その分の区切りも入らない(空欄を飛ばせる)。

繰り返しには `REPLICATE`。

```sql
-- 会員ランクを ★ の数で可視化するイメージ
SELECT ProductName,
       REPLICATE(N'★', 3) AS 星3つ,
       REPLICATE(N'-', 10) AS 罫線
FROM   dbo.Products;
```

## 5. 数値の書式化(FORMAT)

`FORMAT` は .NET の書式指定文字列で、桁区切りや通貨・パーセント表示ができます。

```sql
SELECT ProductName,
       FORMAT(UnitPrice, N'N0')       AS カンマ区切り,   -- 128,000
       FORMAT(UnitPrice, N'C', N'ja-JP') AS 通貨表示     -- ￥128,000
FROM   dbo.Products;
```

- `N0` … 桁区切りあり・小数 0 桁。`N2` なら小数 2 桁。
- `C` … 通貨。第 3 引数にカルチャ(`ja-JP` 等)を渡せる。
- 戻り値は **`NVARCHAR`(文字列)**。数値としての計算にはもう使えない点に注意。

> ⚠️ **`FORMAT` は遅い**。内部で .NET CLR を呼ぶため、`CONVERT` 等に比べ大量行で
> 顕著に低速になる。**表示の最終整形だけ**に使い、大量データの一括処理や
> `WHERE`/`JOIN` の条件では避ける。桁区切りが目的なら `CONVERT` のスタイルでも代用可(11 節)。

## 6. 文字列の集約と分割(STRING_AGG / STRING_SPLIT)

`STRING_AGG`(**2017+**)は、複数行の文字列を **区切り付きで 1 つにまとめる** 集計関数。
「顧客ごとの購入商品一覧」のような横持ち表示に便利です。

```sql
-- 顧客ごとに、購入した商品名をカンマ区切りで一覧化
SELECT c.CustomerName,
       STRING_AGG(p.ProductName, N', ') AS 購入商品一覧
FROM   dbo.Customers   AS c
JOIN   dbo.Orders      AS o  ON o.CustomerId = c.CustomerId
JOIN   dbo.OrderDetails AS od ON od.OrderId = o.OrderId
JOIN   dbo.Products    AS p  ON p.ProductId = od.ProductId
GROUP  BY c.CustomerName;
```

- 並び順を指定したいときは `STRING_AGG(...) WITHIN GROUP (ORDER BY p.ProductName)`。
- NULL の要素は無視される。

逆に、区切り文字列を **行に分解** するのが `STRING_SPLIT`(**2016+**)。

```sql
SELECT value
FROM   STRING_SPLIT(N'東京,大阪,名古屋', N',');
```

> ⚠️ SQL Server 2016 の `STRING_SPLIT` は `value` 列のみで **順序(序数)を返さない**。
> 序数列 `ordinal` が使えるのは **2022 以降**(かつ第 3 引数に `1` を指定)。

## 7. 日付・時刻の「今」を取得する

```sql
SELECT GETDATE()      AS 現在_datetime,     -- 精度3.33ミリ秒・ローカル時刻
       SYSDATETIME()  AS 現在_datetime2;    -- 高精度(7桁)・ローカル時刻
```

- `GETDATE()` … `datetime` 型。従来からある関数。
- `SYSDATETIME()` … `datetime2(7)` 型で **より高精度**。新規コードはこちらが無難。
- UTC が要るなら `SYSUTCDATETIME()`、タイムゾーン付きは `SYSDATETIMEOFFSET()`。

## 8. 日付の部品を取り出す(YEAR / MONTH / DAY / DATEPART / DATENAME)

```sql
SELECT OrderDate,
       YEAR(OrderDate)              AS 年,
       MONTH(OrderDate)             AS 月,
       DAY(OrderDate)               AS 日,
       DATEPART(QUARTER, OrderDate) AS 四半期,
       DATEPART(WEEKDAY, OrderDate) AS 曜日番号,
       DATENAME(WEEKDAY, OrderDate) AS 曜日名
FROM   dbo.Orders;
```

- `YEAR/MONTH/DAY` … よく使う部品の専用関数(`DATEPART(YEAR, ...)` と同じ)。
- `DATEPART(部品, 日付)` … 数値で返す(`QUARTER`・`WEEK`・`HOUR` など幅広い)。
- `DATENAME(部品, 日付)` … 文字列で返す(曜日名・月名など)。

> ⚠️ `WEEKDAY` の番号は設定 `@@DATEFIRST`(週の開始曜日)に依存する。
> 曜日で分岐するロジックは環境差に注意。

## 9. 日付の加減算と差(DATEADD / DATEDIFF)

```sql
-- 出荷までの日数(未出荷=ShipDate NULL は結果も NULL)
SELECT OrderId, OrderDate, ShipDate,
       DATEDIFF(DAY, OrderDate, ShipDate) AS 出荷までの日数
FROM   dbo.Orders;

-- 注文日の30日後(支払期限のイメージ)
SELECT OrderId, OrderDate,
       DATEADD(DAY, 30, OrderDate) AS 支払期限
FROM   dbo.Orders;
```

- `DATEADD(単位, 量, 日付)` … 日付に一定量を加算(負で減算)。
- `DATEDIFF(単位, 開始, 終了)` … **開始から終了までの、単位境界をまたいだ回数**。

> ⚠️ `DATEDIFF` は「境界の数」を数える。例えば `DATEDIFF(YEAR, '2023-12-31', '2024-01-01')`
> は **1**(1 日差でも年境界を 1 回またぐ)。単純な満年齢・満勤続年数の計算では
> **過大になる**ことがある。厳密な満年数は次項の工夫が必要。

### 応用: 勤続年数(満年数)を正しく出す

`DATEDIFF(YEAR, ...)` は月日を無視するため、誕生日/入社応当日をまだ迎えていない
場合に 1 多く出る。応当日到達を補正する定番イディオム。

```sql
SELECT LastName, FirstName, HireDate,
       DATEDIFF(YEAR, HireDate, GETDATE())
         - CASE WHEN DATEADD(YEAR, DATEDIFF(YEAR, HireDate, GETDATE()), HireDate) > GETDATE()
                THEN 1 ELSE 0 END AS 勤続年数
FROM   dbo.Employees;
```

## 10. 月初・月末・部品からの生成(EOMONTH / DATEFROMPARTS)

```sql
SELECT OrderDate,
       DATEFROMPARTS(YEAR(OrderDate), MONTH(OrderDate), 1) AS 月初,
       EOMONTH(OrderDate)                                  AS 月末,       -- 2016+
       EOMONTH(OrderDate, 1)                               AS 翌月末      -- 第2引数=月オフセット
FROM   dbo.Orders;
```

- `EOMONTH(日付[, 月オフセット])`(**2016+**)… その月(またはオフセット月)の **末日** を返す。
- `DATEFROMPARTS(年, 月, 日)`(**2012+**)… 数値部品から `date` 値を組み立てる。
  月初は「日 = 1」で作れる。時刻付きなら `DATETIMEFROMPARTS` など。

## 11. 数値関数(丸め・符号・べき乗)と整数除算の罠

```sql
SELECT UnitPrice,
       ROUND(UnitPrice, -2)   AS 百の位で丸め,   -- 128000 → 128000, 2800→2800
       ROUND(UnitPrice, -3)   AS 千の位で丸め,
       CEILING(UnitPrice / 1000.0) AS 千単位切上げ,
       FLOOR(UnitPrice / 1000.0)   AS 千単位切捨て,
       ABS(-5)                AS 絶対値,
       POWER(2, 10)           AS 2の10乗
FROM   dbo.Products;
```

- `ROUND(数値, 桁)` … 四捨五入。桁が **負なら整数部** の丸め(-2=百の位)。
  `ROUND(x, 桁, 1)` と第 3 引数を非 0 にすると **切り捨て**(丸めずに桁を落とす)。
- `CEILING` / `FLOOR` … 切り上げ / 切り捨て(最も近い整数へ)。
- `ABS` / `POWER` / `SQRT` なども同様に使える。

> ⚠️ **整数どうしの割り算は整数になる**(小数切り捨て)。`5 / 2` は `2.5` ではなく `2`。
> 小数がほしければ **どちらかを小数にする**: `5 / 2.0`、`5.0 / 2`、または
> `CAST(a AS DECIMAL(10,2)) / b`。割引率など小数を含む計算では特に注意。

明細金額 `Quantity * UnitPrice * (1 - Discount)` を丸める例。

```sql
SELECT OrderId, ProductId,
       ROUND(Quantity * UnitPrice * (1 - Discount), 0) AS 明細金額_丸め
FROM   dbo.OrderDetails;
```

## 12. 型変換(CAST / CONVERT / TRY_ 系 / PARSE)

### CAST — 標準的な型変換

```sql
SELECT CAST(UnitPrice AS INT)         AS 整数化,
       CAST(UnitPrice AS VARCHAR(20)) AS 文字列化
FROM   dbo.Products;
```

`CAST(式 AS 型)` は ANSI 標準の書き方。まずはこれを基本に。

### CONVERT — スタイル指定で日付を書式化

`CONVERT(型, 式, スタイル)` は SQL Server 固有で、**第 3 引数のスタイル番号** により
特に **日付の文字列化フォーマット** を制御できます。

```sql
SELECT OrderDate,
       CONVERT(VARCHAR(10), OrderDate, 111) AS 日付_スラッシュ,  -- 2023/01/15
       CONVERT(VARCHAR(10), OrderDate, 23)  AS 日付_ISO,        -- 2023-01-15
       CONVERT(VARCHAR(8),  OrderDate, 112) AS 日付_連番         -- 20230115
FROM   dbo.Orders;
```

- 代表的スタイル: `111`=`yyyy/mm/dd`、`23`=`yyyy-mm-dd`、`112`=`yyyymmdd`、`120`=`yyyy-mm-dd hh:mi:ss`。
- 桁区切り金額なら `CONVERT(VARCHAR, CAST(UnitPrice AS MONEY), 1)`(例: `128,000.00`)。
  `FORMAT` より高速なので、大量行の整形はこちらが有利。

### TRY_CAST / TRY_CONVERT — 失敗しても落ちない

変換できない値があると `CAST`/`CONVERT` は **エラーで停止** します。
`TRY_` 系は失敗時に **NULL を返す**(2012+)ので、汚いデータの検査に向きます。

```sql
SELECT TRY_CAST(N'123'   AS INT) AS 成功,   -- 123
       TRY_CAST(N'abc'   AS INT) AS 失敗,   -- NULL(エラーにならない)
       TRY_CONVERT(DATE, N'2023-02-30') AS 不正日付;  -- NULL
```

- 「数値に変換できる行だけ処理したい」ときは `WHERE TRY_CONVERT(INT, 列) IS NOT NULL`。

### PARSE(概説)

`PARSE(式 AS 型 USING カルチャ)`(2012+)は、`'2023年1月15日'` のような
**ロケール依存の文字列** を日付・数値に解釈する関数。CLR 依存で **非常に遅く**、
失敗時はエラー(NULL 版は `TRY_PARSE`)。通常は `CONVERT`/`TRY_CONVERT` で足り、
`PARSE` は特殊な書式のときの最終手段と考えてよい。

## よくあるつまずき

- **`+` 連結で結果が NULL** → NULL 列が混ざっている。`CONCAT` / `CONCAT_WS`(2017+)を使う。
- **`STRING_AGG`/`CONCAT_WS`/`TRIM` が動かない** → **2017 以降**の機能。バージョンを確認。
- **`STRING_SPLIT` に `ordinal` が無いと言われる** → 序数列は **2022+**。2016 では順序不定。
- **`5/2` が `2` になる** → 整数除算。`5/2.0` などで小数化する。
- **`DATEDIFF(YEAR, ...)` の年数が 1 多い** → 境界カウントのため。応当日で補正する(9 節)。
- **`FORMAT` で集計が遅い** → CLR 呼び出しで低速。表示の最終段だけに使い、`CONVERT` を検討。
- **`CAST` が変換エラーで全体停止** → 汚いデータには `TRY_CAST`/`TRY_CONVERT` を使う。

## この章のまとめ

- 文字列: `LEN`/`DATALENGTH`、`LEFT`/`RIGHT`/`SUBSTRING`、`CHARINDEX`+`SUBSTRING` で抽出、
  `REPLACE`、`TRIM`(2017+)、連結は `CONCAT`/`CONCAT_WS`(2017+)、`STRING_AGG`(2017+)。
- 日付: `SYSDATETIME`/`GETDATE`、`DATEADD`/`DATEDIFF`(境界カウントに注意)、
  `YEAR`/`MONTH`/`DAY`/`DATEPART`、`EOMONTH`(2016+)、`DATEFROMPARTS`。
- 数値: `ROUND`/`CEILING`/`FLOOR`/`ABS`/`POWER`、**整数除算**に注意。
- 変換: `CAST` 基本、`CONVERT` はスタイル、`TRY_CAST`/`TRY_CONVERT` は失敗で NULL、`PARSE` は最終手段。
- **バージョン依存**(2016/2017/2022)と **`FORMAT` の性能** を常に意識する。

➡ 演習: [exercises/12_builtin_functions.md](../exercises/12_builtin_functions.md)
