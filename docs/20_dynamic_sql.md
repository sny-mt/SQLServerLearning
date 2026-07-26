# 20 動的SQL

> **このトピックのゴール**: SQL文そのものを **文字列として組み立てて実行する** 動的SQLを、
> **安全に**書けるようになる。`EXEC()` と `sp_executesql` の違いを理解し、
> パラメータ化と `QUOTENAME()` で **SQLインジェクションを防ぐ**方法を身に付ける。
> 10章で宿題として残した **動的 PIVOT** を完成させ、可変検索条件(catch-all query)の
> 定石も押さえる。
>
> **前提**: [19 トランザクションと分離レベル](19_transactions_isolation.md) までを済ませ、
> [15 一時テーブルとテーブル変数](15_temp_tables.md) と
> [16 ストアドプロシージャとユーザー定義関数](16_stored_procedures.md) の内容を理解していること。
> `SalesLearning` を構築済みであること。

すべての例は先頭で `USE SalesLearning;` を実行済みとします。
明細金額は一貫して `Quantity * UnitPrice * (1 - Discount)` で計算します。

> ⚠️ **この章はデータを壊さないための約束**
> 動的SQLでデータを変更する例は、13章・19章と同じく **`BEGIN TRAN` … `ROLLBACK`** で囲みます。
> プロシージャを作る例は、必ず最後に `DROP PROCEDURE IF EXISTS` で後片付けまで書きます。
> サンプルDBに余計なオブジェクトを残さないでください。

---

## 1. 動的SQLとは何か

動的SQL(dynamic SQL)とは、**SQL文を文字列変数の中に組み立て、その文字列を実行する**手法です。

```sql
DECLARE @sql NVARCHAR(MAX);

SET @sql = N'SELECT ProductId, ProductName, UnitPrice
FROM   dbo.Products
ORDER  BY ProductId;';

EXEC sys.sp_executesql @sql;
```

普通のSQLは「書いた時点で構造が決まっている」のに対し、動的SQLは
**実行時になって初めて構造が決まる**のが特徴です。

### いつ必要になるか

動的SQLが**本当に必要**なのは、「値」ではなく **SQLの構造そのもの** が実行時に決まる場合だけです。

| 状況 | 例 |
|---|---|
| **列名が実行時に決まる** | 画面で選ばれた列だけを出力する |
| **テーブル名が実行時に決まる** | `Sales_2023` / `Sales_2024` のように年ごとに分かれたテーブルを横断する |
| **`ORDER BY` の対象列が実行時に決まる** | 一覧画面の「列ヘッダをクリックして並べ替え」 |
| **検索条件の数が可変** | 検索フォームの入力欄が10個あり、埋まった欄だけで絞り込む |
| **`PIVOT` の列見出しが可変** | 年が増えるたびに列を手で足したくない(10章の宿題) |
| **DDL をプログラムで生成** | 全テーブルに対して一括でインデックスを作る保守スクリプト |

共通しているのは、**「識別子(列名・テーブル名)や句の有無」がパラメータでは表現できない**という点です。
これが動的SQLの存在理由です。

## 2. 逆に、動的SQLを使うべきでないケース

初心者がまずやりがちなのは、**パラメータで足りるのに動的SQLを書いてしまう**ことです。
動的SQLは可読性・デバッグ性・安全性のすべてで劣るので、**回避できるなら必ず回避**します。

```sql
-- ✗ 不要な動的SQL: 値を埋め込みたいだけ
DECLARE @CategoryId INT = 1;
DECLARE @sql NVARCHAR(MAX) =
    N'SELECT ProductName FROM dbo.Products WHERE CategoryId = ' + CAST(@CategoryId AS NVARCHAR(10));
EXEC sys.sp_executesql @sql;

-- ○ 普通に変数を書けばよい
SELECT ProductName FROM dbo.Products WHERE CategoryId = @CategoryId;
```

「動的SQLにしなくても書ける」代表例を押さえておきましょう。

```sql
-- 件数(TOP)は変数でよい。カッコが必要な点に注意
DECLARE @n INT = 5;
SELECT TOP (@n) ProductName, UnitPrice
FROM   dbo.Products
ORDER  BY UnitPrice DESC;

-- ページングも変数でよい(3章)
DECLARE @Skip INT = 10, @Take INT = 5;
SELECT ProductId, ProductName
FROM   dbo.Products
ORDER  BY ProductId
OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;

-- 可変長の IN リストは STRING_SPLIT(SQL Server 2016 以降)で分解できる
DECLARE @Ids NVARCHAR(200) = N'1,3,5,7';
SELECT CustomerId, CustomerName
FROM   dbo.Customers
WHERE  CustomerId IN (SELECT CAST(value AS INT) FROM STRING_SPLIT(@Ids, N','));
```

- **`TOP (@n)`** / **`OFFSET @x ROWS FETCH NEXT @y ROWS ONLY`** は変数を直接書けます。
- 可変長リストは `STRING_SPLIT`(2016+)か、より型安全な **テーブル値パラメータ**
  ([17 ユーザー定義型と TVP](17_user_defined_types.md))で渡します。
- 「テーブルが2つのどちらか」程度なら、**プロシージャを2つに分ける**ほうが速く・読みやすく・安全です。

> ⚠️ 判断基準はシンプルです。**「変わるのは値か、構造か」**。
> 値だけならパラメータ。構造(識別子・句の有無)が変わるときだけ動的SQL。

## 3. `EXEC('...')` と `sp_executesql` の違い

文字列を実行する方法は2つあります。

```sql
-- 方法A: EXEC()(EXECUTE の短縮形)
EXEC (N'SELECT COUNT(*) AS 顧客数 FROM dbo.Customers;');

-- 方法B: sys.sp_executesql(推奨)
EXEC sys.sp_executesql N'SELECT COUNT(*) AS 顧客数 FROM dbo.Customers;';
```

| | `EXEC('...')` | `sys.sp_executesql` |
|---|---|---|
| パラメータを渡せる | **不可**(連結するしかない) | **可能**(`@params` で宣言) |
| OUTPUT で値を受け取る | 不可 | **可能** |
| 実行プランの再利用 | 値ごとに別のSQL文になるので **再利用されにくい** | パラメータ化されるので **再利用される** |
| SQLインジェクション | 連結必須のため **危険** | パラメータ化で **防げる** |
| 引数の型 | `VARCHAR` / `NVARCHAR` どちらも可 | **`NVARCHAR` のみ**(`N'...'` 必須) |
| 呼び出し中の連結 | `EXEC (@a + @b)` と書ける | 不可(先に変数へ組み立てる) |

**結論: 原則 `sys.sp_executesql` を使う。** `EXEC()` は、
「パラメータが1つも無い完全に静的な文字列」や「リンクサーバー実行(`EXEC(...) AT ...`)」など、
限られた場面だけにとどめます。

### `sp_executesql` のパラメータの渡し方

引数は **3つのかたまり** で構成されます。

```sql
DECLARE @sql    NVARCHAR(MAX);
DECLARE @params NVARCHAR(MAX);

SET @sql = N'
SELECT ProductId, ProductName, UnitPrice
FROM   dbo.Products
WHERE  CategoryId = @CategoryId
  AND  UnitPrice >= @MinPrice
ORDER  BY UnitPrice DESC;';

SET @params = N'@CategoryId INT, @MinPrice DECIMAL(18,2)';   -- ② 宣言部

EXEC sys.sp_executesql
     @sql,                       -- ① 実行するSQL文(NVARCHAR)
     @params,                    -- ② パラメータの宣言(NVARCHAR)
     @CategoryId = 1,            -- ③ 実際の値
     @MinPrice   = 5000;
```

- **①** 実行するSQL文。`NVARCHAR(MAX)` を使う(理由は9章)。
- **②** パラメータの**宣言**。`DECLARE` と同じ書式をカンマ区切りで並べます。
- **③** 実際の値。`@名前 = 値` の形で渡します。

> ⚠️ ②の型は、比較する **列の型に合わせる** こと。
> 列が `NVARCHAR(50)` なのにパラメータを `VARCHAR(50)` にすると暗黙の型変換が起こり、
> インデックスが使われなくなることがあります([18 インデックスと実行プラン](18_indexes_execution_plans.md))。

### OUTPUT パラメータで値を受け取る

動的SQLの中で計算した値を、呼び出し元の変数に戻せます。
宣言部と実引数の **両方に `OUTPUT`** を書くのがポイントです。

```sql
DECLARE @CustomerId INT = 1;
DECLARE @OrderCount INT;
DECLARE @Total      DECIMAL(18,2);

EXEC sys.sp_executesql
     N'SELECT @cnt = COUNT(DISTINCT o.OrderId),
              @sum = SUM(od.Quantity * od.UnitPrice * (1 - od.Discount))
       FROM   dbo.Orders       AS o
       JOIN   dbo.OrderDetails AS od ON od.OrderId = o.OrderId
       WHERE  o.CustomerId = @CustomerId;',
     N'@CustomerId INT, @cnt INT OUTPUT, @sum DECIMAL(18,2) OUTPUT',
     @CustomerId = @CustomerId,
     @cnt = @OrderCount OUTPUT,      -- ← ここにも OUTPUT が必要
     @sum = @Total      OUTPUT;

SELECT @OrderCount AS 注文件数, @Total AS 売上合計;
```

> ⚠️ 呼び出し側の `OUTPUT` を書き忘れると **エラーにならず、変数が NULL のまま**になります。
> 「なぜか結果が NULL」のときは真っ先にここを疑ってください。

## 4. SQLインジェクション — この章の最重要事項

動的SQLの最大の危険は **SQLインジェクション** です。
ユーザー入力を文字列連結でSQLに埋め込むと、入力がデータではなく **SQLコードとして解釈**されます。

### 危険な例(絶対に書かないこと)

```sql
-- ✗✗✗ 危険: ユーザー入力を直接連結している
DECLARE @Input NVARCHAR(100) = N'アルファ商事';
DECLARE @bad   NVARCHAR(MAX);

SET @bad = N'SELECT CustomerId, CustomerName FROM dbo.Customers
             WHERE CustomerName = N''' + @Input + N''';';
EXEC (@bad);        -- 1行だけ返る。ここまでは「一見」正しく動く
```

ところが、入力がこうなると破綻します。

```sql
-- ✗✗✗ 攻撃入力: シングルクォートで文字列を閉じ、条件を無効化する
SET @Input = N''' OR 1 = 1 --';

SET @bad = N'SELECT CustomerId, CustomerName FROM dbo.Customers
             WHERE CustomerName = N''' + @Input + N''';';
PRINT @bad;
-- 生成されるSQL:
--   SELECT ... WHERE CustomerName = N'' OR 1 = 1 --';
EXEC (@bad);        -- 顧客12件が全部返ってしまう(絞り込みが消滅)
```

`--` から後ろがコメント扱いになり、閉じクォートが無害化されている点に注目してください。
同じ手口で `'; DROP TABLE dbo.Customers; --` のような **文の追加**も可能です。
「検索画面から全社の顧客情報が抜ける」「テーブルが消える」は、この一行から起こります。

### 安全な例(パラメータ化)

```sql
-- ○ パラメータ化: 入力は「ただの文字列」としてしか扱われない
DECLARE @Input NVARCHAR(100) = N''' OR 1 = 1 --';

EXEC sys.sp_executesql
     N'SELECT CustomerId, CustomerName
       FROM   dbo.Customers
       WHERE  CustomerName = @Name;',
     N'@Name NVARCHAR(100)',
     @Name = @Input;      -- → 0行(そんな名前の顧客は存在しない)。攻撃は成立しない
```

パラメータ化されたSQLでは、`@Name` の中身は **どんな文字列でも値として扱われ、
決してSQL構文として解釈されません**。これが「パラメータ化がインジェクション対策になる」理由です。
おまけに実行プランも再利用されるので、**安全性と性能が同時に手に入ります**。

> ⚠️ 「入力から `'` を除去する」「`--` を弾く」といった**ブラックリスト方式は破られます**。
> 対策は**パラメータ化ただ一つ**だと覚えてください。

### どうしても文字列リテラルを連結するしかないとき

パラメータが使えない特殊な場面(生成したスクリプトを別プロセスへ渡すなど)では、
`QUOTENAME(@s, '''')` で **シングルクォートを二重化した安全なリテラル**を作れます。あくまで次善策です。

```sql
DECLARE @Input NVARCHAR(100) = N''' OR 1 = 1 --';
SELECT QUOTENAME(@Input, '''') AS 安全なリテラル;
-- → ''' OR 1 = 1 --' が正しくエスケープされ、値として閉じ込められる
```

## 5. 識別子はパラメータにできない → `QUOTENAME()`

ここが動的SQLの本質的なジレンマです。**列名・テーブル名などの識別子は、
パラメータとして渡せません。**

```sql
-- ✗ こう書いても「@col という名前の文字列」を並べ替えるだけで、意図どおり動かない
EXEC sys.sp_executesql N'SELECT * FROM dbo.Products ORDER BY @col;',
     N'@col SYSNAME', @col = N'UnitPrice';
```

したがって識別子は **連結せざるを得ません**。そのとき必ず `QUOTENAME()` を通します。

```sql
SELECT QUOTENAME(N'UnitPrice')          AS 通常;      -- [UnitPrice]
SELECT QUOTENAME(N'税込 単価')          AS 空白入り;  -- [税込 単価]
SELECT QUOTENAME(N'x] ; DROP TABLE y--') AS 攻撃入力; -- [x]] ; DROP TABLE y--]
```

- `QUOTENAME()` は文字列を **角括弧で囲み、中に含まれる `]` を `]]` に二重化**します。
- その結果、どんな文字列も **「1個の識別子」として閉じ込められ**、SQL構文からはみ出せません。
- 空白や日本語を含む識別子も正しく扱えるという副次的な利点もあります。

### `QUOTENAME` だけでは足りない — ホワイトリスト検証との併用

`QUOTENAME` は「構文からはみ出さない」ことを保証しますが、
**「存在しない列を指定された」「見せてはいけない列を指定された」** ことは防げません。
実務では **必ずホワイトリスト検証と併用**します。

```sql
DECLARE @SortColumn SYSNAME      = N'UnitPrice';
DECLARE @SortDir    NVARCHAR(4)  = N'DESC';
DECLARE @sql        NVARCHAR(MAX);

-- ① 許可した列だけを通す(列挙によるホワイトリスト)
IF @SortColumn NOT IN (N'ProductId', N'ProductName', N'UnitPrice')
    THROW 50001, N'許可されていない並べ替え列が指定されました。', 1;

-- ② 方向も列挙で検証する(ここを連結すると穴になる)
IF @SortDir NOT IN (N'ASC', N'DESC')
    THROW 50002, N'並べ替え方向は ASC / DESC のみです。', 1;

SET @sql = N'SELECT ProductId, ProductName, UnitPrice
FROM   dbo.Products
ORDER  BY ' + QUOTENAME(@SortColumn) + N' ' + @SortDir + N';';

PRINT @sql;                     -- ③ 生成SQLを目視確認
EXEC sys.sp_executesql @sql;
```

テーブル名を受け取る場合は、**カタログビューで実在を確認**するのが確実です。

```sql
DECLARE @TableName SYSNAME = N'Orders';
DECLARE @sql NVARCHAR(MAX), @cnt INT;

-- 実在するユーザーテーブルかを OBJECT_ID で検証(存在しなければ NULL)
IF OBJECT_ID(N'dbo.' + QUOTENAME(@TableName), N'U') IS NULL
    THROW 50003, N'指定されたテーブルは存在しません。', 1;

SET @sql = N'SELECT @c = COUNT(*) FROM dbo.' + QUOTENAME(@TableName) + N';';
EXEC sys.sp_executesql @sql, N'@c INT OUTPUT', @c = @cnt OUTPUT;

SELECT @TableName AS テーブル, @cnt AS 行数;
```

- 列の実在確認なら `sys.columns` を使います
  (`WHERE object_id = OBJECT_ID(N'dbo.Products') AND name = @SortColumn`)。
- **原則: 識別子は「連結する前に検証」「連結するときは `QUOTENAME`」の二重防御。**

## 6. 動的 PIVOT の実装(10章の回収)

[10 PIVOT / UNPIVOT](10_pivot_unpivot.md) で「`PIVOT` の `IN (...)` はリテラルの並びなので、
列見出しを動的にはできない」と説明し、宿題として残しました。ここで完成させます。

手順は **3段構え** です。

1. 実データから **列見出しの一覧**を文字列として組み立てる(`QUOTENAME` 必須)
2. その一覧を埋め込んで **`PIVOT` 文の文字列**を組み立てる
3. `sp_executesql` で実行する

### STRING_AGG 版(SQL Server 2017 以降)

```sql
DECLARE @cols NVARCHAR(MAX);
DECLARE @sql  NVARCHAR(MAX);

-- ① 実在する年から列見出しの一覧を作る → [2023], [2024]
SELECT @cols = STRING_AGG(QUOTENAME(y.年), N', ') WITHIN GROUP (ORDER BY y.年)
FROM   (SELECT DISTINCT YEAR(o.OrderDate) AS 年 FROM dbo.Orders AS o) AS y;

SELECT @cols AS 生成した列リスト;

-- ② PIVOT 文を組み立てる
SET @sql = N'
SELECT *
FROM (
    SELECT c.Region                                       AS 地域,
           YEAR(o.OrderDate)                              AS 年,
           od.Quantity * od.UnitPrice * (1 - od.Discount) AS 売上
    FROM   dbo.Orders       AS o
    JOIN   dbo.Customers    AS c  ON c.CustomerId = o.CustomerId
    JOIN   dbo.OrderDetails AS od ON od.OrderId   = o.OrderId
) AS src
PIVOT ( SUM(売上) FOR 年 IN (' + @cols + N') ) AS pvt
ORDER  BY 地域;';

-- ③ 生成SQLを確認してから実行する
PRINT @sql;
EXEC sys.sp_executesql @sql;
```

- ソースが **「地域 / 年 / 売上」の3列だけ**である点は静的 `PIVOT` と同じ鉄則です(10章3節)。
- `STRING_AGG(..., N', ')` は **SQL Server 2017 以降**。`WITHIN GROUP (ORDER BY ...)` で
  列の並び順を安定させます(これが無いと年の順序が不定になり得ます)。
- 年は数値なので、そのままでは識別子になりません。**`QUOTENAME` が `[2023]` の角括弧を付けます。**

### FOR XML PATH 版(SQL Server 2016 でも動く)

`STRING_AGG` が使えない環境では、古典的な `FOR XML PATH` + `STUFF` で連結します。

```sql
DECLARE @cols NVARCHAR(MAX);

SELECT @cols = STUFF((
        SELECT N', ' + QUOTENAME(y.年)
        FROM   (SELECT DISTINCT YEAR(o.OrderDate) AS 年 FROM dbo.Orders AS o) AS y
        ORDER  BY y.年
        FOR XML PATH(N''), TYPE
    ).value(N'.', N'NVARCHAR(MAX)'), 1, 2, N'');

SELECT @cols AS 生成した列リスト;   -- [2023], [2024]
```

- `FOR XML PATH(N'')` で要素名なしの連結文字列を作ります。
- `.value(N'.', N'NVARCHAR(MAX)')` を通すのは、`&` や `<` が実体参照に化けるのを防ぐためです。
- `STUFF(..., 1, 2, N'')` は先頭の区切り `', '`(2文字)を削っています。

### 空セルを 0 で埋めたいとき

`PIVOT` は該当なしのセルを NULL にします。列リストが動的なので、
**0埋め用の `SELECT` リストも動的に組み立てる**必要があります。

```sql
DECLARE @cols NVARCHAR(MAX), @selectList NVARCHAR(MAX), @sql NVARCHAR(MAX);

SELECT @cols       = STRING_AGG(QUOTENAME(y.年), N', ') WITHIN GROUP (ORDER BY y.年),
       @selectList = STRING_AGG(N'COALESCE(' + QUOTENAME(y.年) + N', 0) AS ' + QUOTENAME(y.年),
                                N', ') WITHIN GROUP (ORDER BY y.年)
FROM   (SELECT DISTINCT YEAR(o.OrderDate) AS 年 FROM dbo.Orders AS o) AS y;

SET @sql = N'
SELECT 地域, ' + @selectList + N'
FROM (
    SELECT c.Region                                       AS 地域,
           YEAR(o.OrderDate)                              AS 年,
           od.Quantity * od.UnitPrice * (1 - od.Discount) AS 売上
    FROM   dbo.Orders       AS o
    JOIN   dbo.Customers    AS c  ON c.CustomerId = o.CustomerId
    JOIN   dbo.OrderDetails AS od ON od.OrderId   = o.OrderId
) AS src
PIVOT ( SUM(売上) FOR 年 IN (' + @cols + N') ) AS pvt
ORDER  BY 地域;';

PRINT @sql;
EXEC sys.sp_executesql @sql;
```

> ⚠️ 動的 PIVOT は強力ですが、**結果の列構成が実行のたびに変わる**という重い副作用があります。
> 呼び出す側(アプリ・BIツール)が列構成の変化に耐えられるかを必ず確認してください。
> 列が固定でよいなら、静的 `PIVOT` か `SUM(CASE WHEN ...)` のほうが常に優れています。

## 7. 可変検索条件(catch-all query)

「検索フォームの入力欄のうち、埋まったものだけで絞り込む」要件は非常によく出てきます。
書き方は大きく3通りあり、それぞれ長所と短所があります。

### 方式A: `(@x IS NULL OR 列 = @x)` — 素朴だがプランが偏る

```sql
DECLARE @City NVARCHAR(50) = N'東京';
DECLARE @Region NVARCHAR(50) = NULL;
DECLARE @SalesRepId INT = NULL;

SELECT CustomerId, CustomerName, City, Region, SalesRepId
FROM   dbo.Customers
WHERE  (@City       IS NULL OR City       = @City)
  AND  (@Region     IS NULL OR Region     = @Region)
  AND  (@SalesRepId IS NULL OR SalesRepId = @SalesRepId)
ORDER  BY CustomerId;
```

読みやすく、静的SQLのままで済むのが利点です。しかし **性能面に明確な問題**があります。

- 実行プランは **最初に実行されたときのパラメータ**でコンパイルされ、キャッシュされます。
- 例えば「`@City` だけ指定」でコンパイルされたプランが、後の
  「`@SalesRepId` だけ指定」の呼び出しにも **そのまま使い回されます**。
- どの列にもインデックスを効かせにくいため、結果として **テーブル全体のスキャン**に倒れがちです。

これが「**パラメータ・スニッフィングによってプランが偏る**」と呼ばれる現象です。

### 方式B: 方式A + `OPTION (RECOMPILE)` — 実務の第一候補

```sql
SELECT CustomerId, CustomerName, City, Region, SalesRepId
FROM   dbo.Customers
WHERE  (@City       IS NULL OR City       = @City)
  AND  (@Region     IS NULL OR Region     = @Region)
  AND  (@SalesRepId IS NULL OR SalesRepId = @SalesRepId)
ORDER  BY CustomerId
OPTION (RECOMPILE);
```

- **毎回コンパイルし直す**ため、その回の実際のパラメータに最適なプランが選ばれます。
- さらに、`@Region IS NULL` が真だと分かっている条件は
  コンパイル時に **丸ごと除去(simplification)** されます。実質「必要な条件だけのSQL」になるわけです。
- 代償は **毎回のコンパイル費用**。実行回数が少なく1回が重いクエリ(検索画面など)には最適ですが、
  秒間何百回も走る軽いクエリには向きません。

### 方式C: 動的SQLで必要な条件だけ組み立てる

```sql
DECLARE @City NVARCHAR(50) = N'東京';
DECLARE @Region NVARCHAR(50) = NULL;
DECLARE @SalesRepId INT = NULL;
DECLARE @sql NVARCHAR(MAX);

SET @sql = N'
SELECT CustomerId, CustomerName, City, Region, SalesRepId
FROM   dbo.Customers
WHERE  1 = 1';                                   -- ← 条件を足しやすくするための定石

IF @City       IS NOT NULL SET @sql += N'
  AND City = @City';
IF @Region     IS NOT NULL SET @sql += N'
  AND Region = @Region';
IF @SalesRepId IS NOT NULL SET @sql += N'
  AND SalesRepId = @SalesRepId';

SET @sql += N'
ORDER BY CustomerId;';

PRINT @sql;                                      -- 生成SQLを必ず確認

EXEC sys.sp_executesql @sql,
     N'@City NVARCHAR(50), @Region NVARCHAR(50), @SalesRepId INT',
     @City = @City, @Region = @Region, @SalesRepId = @SalesRepId;
```

- **`WHERE 1 = 1`** から始めると、条件を常に `AND ...` の形で足せます(先頭判定が不要)。
- 値は必ず **パラメータで渡す**。ここを連結したら4節の脆弱性そのものです。
- 条件の組み合わせごとに **異なるSQL文** になるので、**組み合わせごとに最適なプランがキャッシュ**されます。
  再コンパイルは組み合わせが初登場のときだけで済みます。
- パラメータは、その回に使っていないものも含めて全部渡して構いません(未使用なら無視されます)。

### 使い分けの目安

| 方式 | 向いている場面 |
|---|---|
| A(`IS NULL OR`) | 条件が2〜3個・表が小さい・性能要件がゆるい |
| B(+ `OPTION (RECOMPILE)`) | **検索画面の既定解**。実行頻度が高くなく、1回の重さが問題になる |
| C(動的SQL) | 条件が多い・実行頻度が非常に高くコンパイル費用を避けたい |

> ⚠️ まず **方式B** を試し、コンパイル費用が問題になって初めて **方式C** に進むのが健全な順序です。
> 「なんとなく速そうだから」で最初から動的SQLにしないこと。

## 8. スコープ — 動的SQLの中と外は「別の世界」

動的SQLは **別のバッチとして実行されます**。ここを誤解すると必ずハマります。
[15 一時テーブルとテーブル変数](15_temp_tables.md) の知識と直結する話です。

| 呼び出し元のもの | 動的SQLの中から見えるか |
|---|---|
| ローカル変数 `@v` | **見えない**(`DECLARE` されていないというエラー) |
| テーブル変数 `@t` | **見えない** |
| 一時テーブル `#t` | **見える**(読み書きとも可) |
| グローバル一時テーブル `##t` | 見える |
| 動的SQL内で作った `#t` | **動的SQLが終わると消える**(呼び出し元から見えない) |

```sql
CREATE TABLE #Scope (Id INT, Memo NVARCHAR(50));
INSERT INTO #Scope VALUES (1, N'呼び出し元で作成');

DECLARE @v INT = 99;

-- (a) 呼び出し元の #temp は見える
EXEC sys.sp_executesql N'SELECT * FROM #Scope;';

-- (b) 呼び出し元のローカル変数は見えない
-- EXEC sys.sp_executesql N'SELECT @v;';
--   → Msg 137: スカラー変数 "@v" を宣言してください。

-- (c) 値を渡したいなら「パラメータ」で明示的に渡す
EXEC sys.sp_executesql N'SELECT @v AS 受け取った値;', N'@v INT', @v = @v;

-- (d) 動的SQL内で作った #temp は、外からは見えない
EXEC sys.sp_executesql N'CREATE TABLE #Inner (X INT); INSERT INTO #Inner VALUES (1);';
-- SELECT * FROM #Inner;   -- ✗ オブジェクト名 '#Inner' が無効です

-- (e) 逆に、呼び出し元で作っておけば動的SQL側から書き込める(結果の受け渡しの定石)
EXEC sys.sp_executesql N'INSERT INTO #Scope VALUES (2, N''動的SQLから追加'');';
SELECT * FROM #Scope;

DROP TABLE #Scope;
```

- **動的SQLの結果を呼び出し元に返す**には、次のどちらかが定石です。
  1. `OUTPUT` パラメータで **スカラー値**を返す(3節)
  2. 呼び出し元で **`#temp` を先に作っておき**、動的SQL側から `INSERT` する(上の (e))
- 文字列リテラルの中にさらに文字列リテラルを書くときは、`N''...''` と
  **シングルクォートを二重化**する必要があります。ここが動的SQLの読みにくさの主因です。

> ⚠️ 動的SQLは **所有権の連鎖(ownership chaining)が切れます**。
> ストアドプロシージャの中で動的SQLを使うと、プロシージャの実行権限だけでは足りず、
> 呼び出し元ユーザーに **参照テーブルへの直接権限**が必要になります。
> 権限を広げたくない場合は `CREATE PROCEDURE ... WITH EXECUTE AS OWNER` を検討します
> ([16 ストアドプロシージャ](16_stored_procedures.md))。

## 9. デバッグの実務テク

動的SQLは「文字列を組み立てるプログラム」です。**組み上がった文字列を必ず目で見る**ことが、
デバッグの9割を占めます。

### (1) 実行の前に必ず生成SQLを出力する

```sql
DECLARE @sql NVARCHAR(MAX) = N'SELECT COUNT(*) FROM dbo.Orders;';

PRINT @sql;              -- メッセージタブに出力(改行が保たれて読みやすい)
SELECT @sql AS 生成SQL;  -- 結果グリッドに出力(長文が切れにくい)

EXEC sys.sp_executesql @sql;
```

- **`PRINT`** … 改行がそのまま出るので読みやすい。ただし **`NVARCHAR` は先頭4000文字で切られます**。
- **`SELECT @sql`** … 4000文字を超えても保持されますが、グリッド表示の設定によっては表示が途中で切れます。
- 長いSQLを確実に見たいときは `SELECT CAST(@sql AS XML);` とすると、
  クリックで全文を開けて便利です(SQL Server Management Studio)。

本番のプロシージャには、`@Debug BIT = 0` のような引数を用意して
「1 なら実行せず `PRINT` だけ」にする作りが定番です。

```sql
IF @Debug = 1
    PRINT @sql;
ELSE
    EXEC sys.sp_executesql @sql, @params, @CategoryId = @CategoryId;
```

### (2) `NVARCHAR(MAX)` を使う(長さ切れ防止)

これは初心者が最も踏みやすい地雷です。

```sql
-- ✗ 危険: 4000文字を超えた分は「エラーにならず黙って切れる」
DECLARE @bad NVARCHAR(4000);
SET @bad = N'…長いSQL…';

-- ○ 必ず NVARCHAR(MAX)
DECLARE @sql NVARCHAR(MAX);
```

さらに厄介なのが、**連結の途中で切れる**ケースです。

```sql
-- ✗ 右辺の連結が NVARCHAR(4000) 同士なので、代入前に切り捨てられることがある
DECLARE @a NVARCHAR(4000) = REPLICATE(N'x', 4000);
DECLARE @sql1 NVARCHAR(MAX) = @a + @a;
SELECT LEN(@sql1) AS 切れた長さ;      -- 4000 のまま

-- ○ 先頭に MAX 型を1つ噛ませると、以降の連結が MAX で行われる
DECLARE @sql2 NVARCHAR(MAX) = CAST(N'' AS NVARCHAR(MAX)) + @a + @a;
SELECT LEN(@sql2) AS 正しい長さ;      -- 8000
```

- 変数の宣言だけでなく、**式の途中の型**も `MAX` にする必要があります。
- 定石は「最初の部品を `NVARCHAR(MAX)` の変数に入れてから `+=` で足していく」ことです。

### (3) 生成の失敗パターンを見分ける

- 生成SQLが **空 or NULL** → 連結した部品のどれかが NULL。`CONCAT` を使うか `ISNULL` で守る
  (`STRING_AGG` は対象行が0件のとき **NULL** を返します。動的 PIVOT で要注意)。
- **`'` の数が合わない** → 埋め込む文字列リテラルの二重化を忘れている。
- **識別子が見つからない** → `QUOTENAME` を忘れて空白・日本語入りの名前が壊れている。

### (4) プランが再利用されているか確認する

パラメータ化の効果は、キャッシュされたプランで確認できます(読み取り専用)。

```sql
SELECT TOP (10)
       qs.execution_count AS 実行回数,
       st.text            AS SQL文
FROM   sys.dm_exec_query_stats AS qs
CROSS  APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
WHERE  st.text LIKE N'%dbo.Customers%'
ORDER  BY qs.last_execution_time DESC;
```

- パラメータ化した動的SQLなら、同じSQL文の `実行回数` が増えていきます(再利用されている)。
- 値を連結した動的SQLは、**値ごとに別行**として並びます(毎回コンパイルされている証拠)。

## 10. 動的SQLをプロシージャにまとめる(総合例)

ここまでの要素を全部入れた実用例です。**後片付けまで含めて**示します。

```sql
DROP PROCEDURE IF EXISTS dbo.usp_SearchCustomers;   -- SQL Server 2016 以降の書き方
GO

CREATE PROCEDURE dbo.usp_SearchCustomers
    @City       NVARCHAR(50) = NULL,
    @Region     NVARCHAR(50) = NULL,
    @SalesRepId INT          = NULL,
    @SortColumn SYSNAME      = N'CustomerId',
    @Debug      BIT          = 0
AS
BEGIN
    SET NOCOUNT ON;

    -- ① 識別子はホワイトリストで検証(パラメータにできないため)
    IF @SortColumn NOT IN (N'CustomerId', N'CustomerName', N'City', N'Region')
        THROW 50001, N'許可されていない並べ替え列です。', 1;

    DECLARE @sql NVARCHAR(MAX) = N'
SELECT CustomerId, CustomerName, City, Region, SalesRepId
FROM   dbo.Customers
WHERE  1 = 1';

    -- ② 指定された条件だけを足す。値は必ずパラメータ
    IF @City       IS NOT NULL SET @sql += N'
  AND City = @City';
    IF @Region     IS NOT NULL SET @sql += N'
  AND Region = @Region';
    IF @SalesRepId IS NOT NULL SET @sql += N'
  AND SalesRepId = @SalesRepId';

    -- ③ 識別子は QUOTENAME で囲んで連結
    SET @sql += N'
ORDER BY ' + QUOTENAME(@SortColumn) + N';';

    -- ④ デバッグ時は実行せず生成SQLだけ見せる
    IF @Debug = 1
    BEGIN
        PRINT @sql;
        RETURN;
    END;

    EXEC sys.sp_executesql @sql,
         N'@City NVARCHAR(50), @Region NVARCHAR(50), @SalesRepId INT',
         @City = @City, @Region = @Region, @SalesRepId = @SalesRepId;
END;
GO

-- 動作確認
EXEC dbo.usp_SearchCustomers @City = N'東京', @SortColumn = N'CustomerName';
EXEC dbo.usp_SearchCustomers @Region = N'関西', @Debug = 1;   -- 生成SQLだけ表示
GO

-- 後片付け(サンプルDBに残さない)
DROP PROCEDURE IF EXISTS dbo.usp_SearchCustomers;
GO
```

データを変更する動的SQLは、必ずトランザクションで囲んで試します。

```sql
BEGIN TRAN;

DECLARE @ProductId INT = 2, @Rate DECIMAL(5,2) = 0.90;
DECLARE @sql NVARCHAR(MAX) = N'
UPDATE dbo.Products
SET    UnitPrice = UnitPrice * @Rate
WHERE  ProductId = @ProductId;';

PRINT @sql;
EXEC sys.sp_executesql @sql,
     N'@ProductId INT, @Rate DECIMAL(5,2)',
     @ProductId = @ProductId, @Rate = @Rate;

SELECT ProductId, ProductName, UnitPrice
FROM   dbo.Products WHERE ProductId = @ProductId;   -- 結果を確認

ROLLBACK;   -- 変更をなかったことにする(COMMIT しない)
```

## よくあるつまずき

- **`OUTPUT` の付け忘れ** → 呼び出し側の実引数にも `OUTPUT` が必要。忘れると **無言で NULL**。
- **`sp_executesql` に `VARCHAR` を渡してエラー** → 第1・第2引数は `NVARCHAR` 限定。`N'...'` を付ける。
- **SQLが途中で切れる** → `NVARCHAR(4000)` を使っている、または連結の途中の型が `MAX` でない。
  `CAST(N'' AS NVARCHAR(MAX)) + …` で最初に MAX を噛ませる。
- **生成SQLが NULL になる** → 連結部品のどれかが NULL(`STRING_AGG` は0行なら NULL)。
- **動的SQL内で `@変数` が使えない** → スコープが別。パラメータで明示的に渡す(8節)。
- **動的SQL内で作った `#temp` が外から消える** → 呼び出し元で先に `CREATE TABLE #t` しておく。
- **`ORDER BY @col` が効かない** → 識別子はパラメータ化できない。`QUOTENAME` + ホワイトリストで連結。
- **`PRINT` で長いSQLが途中までしか出ない** → `PRINT` は 4000 文字で切れる。`SELECT @sql` や
  `SELECT CAST(@sql AS XML)` で確認する。
- **プロシージャ内の動的SQLで権限エラー** → 所有権の連鎖が切れる。`EXECUTE AS OWNER` を検討。

## この章のまとめ

- 動的SQLが必要なのは **「値」ではなく「構造」(識別子・句の有無)が実行時に決まる**ときだけ。
  `TOP (@n)` / `OFFSET FETCH` / `STRING_SPLIT` / TVP で済むなら動的SQLにしない。
- 実行は **`sys.sp_executesql` を原則**とする。パラメータ化により
  **インジェクション防止とプラン再利用が同時に得られる**。`EXEC()` は最小限に。
- **SQLインジェクション対策はパラメータ化ただ一つ**。入力のフィルタリングは対策にならない。
- **識別子はパラメータにできない**ので連結するしかない。必ず **`QUOTENAME()`** で囲み、
  さらに **ホワイトリスト検証**(列挙 / `sys.columns` / `OBJECT_ID`)を併用する。
- **動的 PIVOT** は「①列リストを `QUOTENAME`+`STRING_AGG`(または `FOR XML PATH`)で作る →
  ②`PIVOT` 文を組み立てる → ③`sp_executesql` で実行」の3段構え。
- 可変検索条件は **`OPTION (RECOMPILE)` を第一候補**に。コンパイル費用が問題になったら動的SQLへ。
- **`NVARCHAR(MAX)`** を使い、実行前に **`PRINT @sql` / `SELECT @sql`** で必ず目視確認する。
- 動的SQLの中は **別スコープ**。`@変数` は見えず、`#temp` は見える。
  値は `OUTPUT` パラメータ、結果セットは呼び出し元の `#temp` 経由で受け渡す。

➡ 演習: [exercises/20_dynamic_sql.md](../exercises/20_dynamic_sql.md)
