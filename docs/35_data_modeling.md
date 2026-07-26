# 35 データモデリングと物理設計

> **このトピックのゴール**: **どれだけクエリが上手くても、設計が悪ければ性能の上限は決まってしまう**。
> この章では「そもそもこのテーブル構造でよいのか」を判断できるようになる。
> 正規化・非正規化・データ型・キー・制約という **物理設計の5つの決定** が、
> 実行プランと IO 量にどう跳ね返るかを **測って** 理解する。
>
> **前提**: [34 テンポラルテーブルと履歴設計](34_temporal_tables.md) までを済ませていること。
> 7 節以降の計測例は `sample-db/03_bulk_data.sql` の `dbo.OrdersBig`(100万行)を使うので、
> まだなら先に実行してください。

すべての例は先頭で `USE SalesLearning;` を実行済みとします。

> ⚠️ **この章の安全方針**: 実験は **`Demo` で始まる専用テーブル** だけで行い、
> 最後の 12 節ですべて `DROP TABLE IF EXISTS` します。
> **`dbo.Orders` などの既存テーブルは一切変更しません**。

---

## 1. 設計が性能の上限を決める

01〜34 で学んできたのは「与えられたテーブルから、いかに速く正しく取り出すか」でした。
しかし現場で本当に手に負えない遅さの多くは、**クエリではなくスキーマが原因**です。

| 設計上の決定 | 何に効くか | 手遅れになったときの代償 |
|---|---|---|
| 正規化の度合い | 更新の整合性、結合の本数 | データが壊れる。修復は不可能に近い |
| データ型 | **行サイズ → ページあたり行数 → IO 量** | 全クエリが一律に遅い。型変更は全表再構築 |
| キーの選択 | クラスター化インデックスの効き、断片化 | 断片化と全非クラスタ化インデックスの肥大 |
| 制約の有無と信頼状態 | **オプティマイザが使える前提知識** | プランが最適化されない(気づかれない) |
| OLTP か分析かの見極め | インデックス種別、パーティション | 用途に合わない構造で全部が中途半端 |

クエリのチューニングは **後から何度でもできます**。
しかしデータ型やキーの変更は、テーブル全体の再構築・アプリの全面改修を伴います。
**設計は「取り返しがつかないチューニング」** なのです。

この章の実験に使う専用テーブルを1つ用意しておきます。

```sql
-- 実験用テーブル(既存表からコピーするだけ。既存表は変更しない)
DROP TABLE IF EXISTS dbo.DemoOrders;

SELECT OrderId, CustomerId, EmployeeId, OrderDate, ShipDate, Status, Amount
INTO   dbo.DemoOrders
FROM   dbo.OrdersBig;

ALTER TABLE dbo.DemoOrders
    ADD CONSTRAINT PK_DemoOrders PRIMARY KEY CLUSTERED (OrderId);
```

- `SELECT ... INTO` は **列の NULL 可否は引き継ぎますが、制約もインデックスも引き継ぎません**。
  だから主キーは自分で付け直します。
- `dbo.OrdersBig` が無い場合は `sample-db/03_bulk_data.sql` を先に実行してください。

---

## 2. 正規化 — 「何が壊れるか」で理解する

正規形の定義を暗記しても設計はできません。覚えるべきは
**「この設計だと、いつ・どうやってデータが壊れるか」** です。

### 2-1. 悪い設計を作ってみる

受注データを「1枚の表」に詰め込んだ、よくある設計です。

```sql
DROP TABLE IF EXISTS dbo.DemoSalesFlat;

CREATE TABLE dbo.DemoSalesFlat
(
    OrderId        INT            NOT NULL,
    ProductId      INT            NOT NULL,
    OrderDate      DATE           NOT NULL,
    CustomerName   NVARCHAR(100)  NOT NULL,   -- 顧客の属性
    CustomerCity   NVARCHAR(50)   NULL,       -- 顧客の属性
    CustomerRegion NVARCHAR(50)   NULL,       -- 顧客の属性
    ProductName    NVARCHAR(100)  NOT NULL,   -- 商品の属性
    CategoryId     INT            NULL,       -- 商品の属性
    CategoryName   NVARCHAR(50)   NULL,       -- ★カテゴリの属性(商品経由)
    ProductTags    NVARCHAR(200)  NULL,       -- ★カンマ区切りで複数値
    Quantity       INT            NOT NULL,
    UnitPrice      DECIMAL(10, 0) NOT NULL,
    CONSTRAINT PK_DemoSalesFlat PRIMARY KEY (OrderId, ProductId)
);

INSERT INTO dbo.DemoSalesFlat
       (OrderId, ProductId, OrderDate, CustomerName, CustomerCity, CustomerRegion,
        ProductName, CategoryId, CategoryName, ProductTags, Quantity, UnitPrice)
VALUES (1001, 1, '2023-01-15', N'アルファ商事', N'東京', N'関東',
        N'ノートPC', 1, N'電化製品', N'PC,モバイル,法人向け', 2, 128000),
       (1001, 2, '2023-01-15', N'アルファ商事', N'東京', N'関東',
        N'ワイヤレスマウス', 1, N'電化製品', N'PC,周辺機器', 5, 2800),
       (1004, 1, '2023-04-02', N'アルファ商事', N'東京', N'関東',
        N'ノートPC', 1, N'電化製品', N'PC,モバイル,法人向け', 1, 128000);
```

### 2-2. 3つの異常(anomaly)

**(a) 更新時異常 (update anomaly)**

「アルファ商事」が「アルファ商事株式会社」に社名変更しました。

```sql
-- 1箇所だけ直してしまった(実際にはこれが起きる)
UPDATE dbo.DemoSalesFlat
SET    CustomerName = N'アルファ商事株式会社'
WHERE  OrderId = 1001 AND ProductId = 1;

-- 同じ顧客なのに名前が2種類ある
SELECT DISTINCT CustomerName FROM dbo.DemoSalesFlat;
```

- 同じ事実が **何行にも重複して書かれている** ため、更新は「全部の行」を漏れなく直す必要があります。
- 1行でも漏れれば **どちらが正なのかデータからは判定不能** になります。
- そして「全部の行」を直すのは、行が増えるほど重く・危険になります。

**(b) 挿入時異常 (insert anomaly)**

新規顧客「ラムダソフト」を登録したい。しかしまだ注文がありません。

```sql
-- 注文が無いので OrderId / ProductId / Quantity に入れる値が無い
-- → ダミー値(0 や -1)を入れるしかなくなる = マジックナンバーの発生源
INSERT INTO dbo.DemoSalesFlat (OrderId, ProductId, OrderDate, CustomerName, ProductName, Quantity, UnitPrice)
VALUES (0, 0, '1900-01-01', N'ラムダソフト', N'(なし)', 0, 0);   -- ✗ こんなことをしてはいけない
```

- **独立して存在できる事実(顧客)が、別の事実(注文)なしには登録できない**。
- 現場ではここで「ダミー行」が生まれ、以後すべての集計クエリに `WHERE OrderId <> 0` が付きます。

**(c) 削除時異常 (delete anomaly)**

```sql
-- 注文1004 をキャンセルして削除する
DELETE FROM dbo.DemoSalesFlat WHERE OrderId = 1004;
```

- もしこれが「デルタ電子の唯一の注文」だったら、**顧客デルタ電子の情報ごと消えます**。
- 消したかったのは注文だけなのに、巻き添えで別の事実が失われる。

> ⚠️ **正規化の目的は「テーブルを増やすこと」ではありません**。
> **1つの事実を1箇所にだけ書く(one fact, one place)** ことで、
> 上の3つの異常を **構造的に起こせなくする** ことです。

### 2-3. 第1正規形 (1NF) — 1つのマスに1つの値

`ProductTags` に `N'PC,モバイル,法人向け'` と詰め込んでいるのが違反です。

```sql
-- タグ「モバイル」が付いた商品を探したい
-- ✗ こう書くしかない。インデックスは絶対に効かない(先頭ワイルドカード LIKE)
SELECT ProductId, ProductTags
FROM   dbo.DemoSalesFlat
WHERE  ',' + ProductTags + ',' LIKE N'%,モバイル,%';
```

何が壊れるか:

- **検索が SARGable にならない**([18 インデックスと実行プラン](18_indexes_execution_plans.md) 4 節)。
- **外部キーを張れない** ので、存在しないタグを書いても止められない。
- `N'PC'` と `N'ＰＣ'`、`N'PC, モバイル'`(空白入り)のような **表記ゆれを制約で防げない**。
- 「タグごとの件数」を出すのに毎回 `STRING_SPLIT`(**2017+**)が必要で、結合コストが乗る。

**代わりにどうするか**: 交差テーブル(多対多)に分解します。

```sql
-- dbo.DemoProductTag (ProductId, TagId) の形にする
--   → タグ検索は等値結合になり、インデックスが効く
--   → FK でタグの存在を保証できる
```

> ⚠️ 「区切り文字で持てば列が増えなくて楽」は、**書くときだけ楽で、読むときに永久に高くつく** 典型です。

### 2-4. 第2正規形 (2NF) — 主キーの一部にだけ依存する列を追い出す

主キーは `(OrderId, ProductId)` です。しかし:

| 列 | 何に依存しているか |
|---|---|
| `OrderDate` | **`OrderId` だけ** |
| `CustomerName` / `CustomerCity` / `CustomerRegion` | **`OrderId` だけ**(注文→顧客) |
| `ProductName` / `CategoryId` | **`ProductId` だけ** |
| `Quantity` / `UnitPrice` | `(OrderId, ProductId)` の**両方**(← これだけが正しい) |

主キーの **一部** にしか依存しない列がある状態を **部分関数従属** といい、これが 2NF 違反です。
そして 2-2 の3つの異常は、まさにここから発生しています。

**分解**: `注文ヘッダ(OrderId, OrderDate, CustomerId)` と `注文明細(OrderId, ProductId, Quantity, UnitPrice)` に分ける。
= サンプルDB の `dbo.Orders` / `dbo.OrderDetails` そのものです。

### 2-5. 第3正規形 (3NF) — キー以外の列に依存する列を追い出す

`ProductId → CategoryId → CategoryName` という連鎖があります。
`CategoryName` は主キーに **直接** 依存せず、`CategoryId` 経由で依存している。
これを **推移的関数従属** といい、3NF 違反です。

何が壊れるか:

- カテゴリ名を「電化製品」→「エレクトロニクス」に変えるには、**そのカテゴリの全商品の全明細行**を更新する必要がある。
- **商品が1つも売れていないカテゴリは、このテーブルには存在できない**(挿入時異常の再発)。

**分解**: `dbo.Categories(CategoryId, CategoryName)` を独立させ、`Products` は `CategoryId` だけを持つ。
= サンプルDB の設計そのものです。

> 3NF の覚え方(有名な言い回し):
> **「キーに、キーの全体に、キー以外の何ものにも依存しない」**
> (the key = 1NF・2NF、the whole key = 2NF、nothing but the key = 3NF)

### 2-6. ボイス・コッド正規形 (BCNF) — 3NF でも足りない場合

3NF を満たしているのに異常が残るケースがあります。**候補キーが複数あって、互いに重なっている**ときです。

例: 「顧客ごと・商品カテゴリごとに担当社員を1人決める。ただし **1人の社員は1つのカテゴリしか担当しない**」。

```sql
DROP TABLE IF EXISTS dbo.DemoAssignment;

CREATE TABLE dbo.DemoAssignment
(
    CustomerId INT NOT NULL,
    CategoryId INT NOT NULL,
    EmployeeId INT NOT NULL,
    CONSTRAINT PK_DemoAssignment PRIMARY KEY (CustomerId, CategoryId),
    CONSTRAINT UQ_DemoAssignment UNIQUE     (CustomerId, EmployeeId)
);

INSERT INTO dbo.DemoAssignment (CustomerId, CategoryId, EmployeeId)
VALUES (1, 1, 2),    -- アルファ商事の電化製品担当は 鈴木花子
       (1, 2, 3),    -- アルファ商事の家具担当は     高橋一郎
       (2, 1, 2);    -- ベータ工業の電化製品担当も   鈴木花子
```

- 候補キーは `(CustomerId, CategoryId)` と `(CustomerId, EmployeeId)` の **2つ**。
- 関数従属 **`EmployeeId → CategoryId`**(社員が決まればカテゴリが決まる)が存在する。
- `CategoryId` は候補キーの一部(素属性)なので **3NF は満たしています**。
  それでも `EmployeeId` は候補キーではないのに他の列を決定している → **BCNF 違反**。

何が壊れるか:

- 鈴木花子の担当カテゴリを「電化製品→家具」に変えるには、**彼女が担当する全顧客の行**を更新する必要がある(更新時異常)。
- **まだ顧客が割り当たっていない社員のカテゴリを登録できない**(挿入時異常)。

**分解**:

```sql
-- dbo.DemoEmployeeCategory (EmployeeId PK, CategoryId)   ← 社員→カテゴリ
-- dbo.DemoCustomerEmployee (CustomerId, EmployeeId) PK   ← 顧客→担当社員
```

> ⚠️ 実務では **3NF まで持っていけば大半の異常は消えます**。
> BCNF が問題になるのは「候補キーが複数あり、かつ重なっている」場合だけです。
> ただし **その形は実在します**(担当割当・時間割・在庫ロケーションなど)。
> 「3NF だから安心」ではなく、**候補キーを全部列挙する** 習慣を持ってください。

### 2-7. 正規化された姿 = サンプルDB

`sample-db/01_create_schema.sql` を読み返すと、ここまでの分解がそのまま形になっています。

```
Categories ──< Products ──< OrderDetails >── Orders >── Customers >── Employees
                                                                          │
Departments ──< Employees ─┘(ManagerId 自己参照)                          ┘
```

- 顧客名は `dbo.Customers` に **1行だけ**。社名変更は 1 UPDATE で終わる。
- 注文の無い顧客(`CustomerId = 11` ラムダソフト)も、**問題なく存在できる**。
- カテゴリの無い商品(`ProductId = 19, 20`)は `CategoryId = NULL` で表現され、ダミー値は不要。

---

## 3. `OrderDetails.UnitPrice` — 冗長に見えて、冗長でないもの

`dbo.OrderDetails` は `UnitPrice` を持っています。
`dbo.Products` にも `UnitPrice` があるのだから、**一見「同じ値が2箇所にある = 正規化違反」に見えます**。

```sql
-- 「Products を見れば分かるのだから、OrderDetails.UnitPrice は要らない」?
SELECT od.OrderId, p.ProductName, od.UnitPrice AS 注文時単価, p.UnitPrice AS 現在単価
FROM   dbo.OrderDetails AS od
JOIN   dbo.Products     AS p ON p.ProductId = od.ProductId
WHERE  od.OrderId = 1001;
```

**これは正規化違反ではありません**。理由:

- `Products.UnitPrice` は **「いまの定価」** という事実。
- `OrderDetails.UnitPrice` は **「2023-01-15 にこの顧客がこの値段で買った」** という別の事実。
- たまたま値が一致する瞬間があるだけで、**意味が違う**。
  `(OrderId, ProductId)` に完全関数従属しているので、**第3正規形を満たしています**。

もしこの列が無ければ何が起きるか:

- 商品が値上げされた瞬間に、**過去の売上が全部書き換わる**。
- 昨日出した月次売上レポートと今日出したものが一致しない。
- 「値引き前の価格で計上していた」という **証跡が消える**(会計・監査上は致命的)。

> ⚠️ **「同じ値がある = 冗長」ではありません**。冗長かどうかは値ではなく **意味(関数従属)** で決まります。
> 判定の質問はいつも同じ: **「元の値が変わったとき、この列も変わるべきか?」**
> - 変わるべき → 冗長。持ってはいけない(または整合性を維持する仕組みが要る)。
> - 変わってはいけない → **別の事実**。持つのが正しい。

この「時点のスナップショット」は設計上のイディオムです。
`Orders.OrderDate` 時点の顧客住所を配送先として残す、契約時点の料率を残す、なども同じ形。
**変化する属性の履歴そのものを管理したいなら**、[34 テンポラルテーブルと履歴設計](34_temporal_tables.md) の
システムバージョン管理テーブルが選択肢になります。

---

## 4. 非正規化の判断基準

3 節は「そもそも非正規化ではなかった」例でした。ここからは **本物の非正規化** の話です。

### 4-1. いつ非正規化してよいか

非正規化とは **「整合性のリスクを買って、読み取り速度を得る取引」** です。
次の条件が **すべて** そろって初めて検討します。

1. **計測済みであること**。「結合が多いから遅そう」ではなく、
   実行プランと論理読み取り数で「この結合/集計がボトルネックだ」と確認できている。
2. **読み取りが書き込みより圧倒的に多い**。更新のたびに再計算が走るので、
   更新が多いと非正規化はむしろ遅くなる。
3. **整合性を維持する仕組みを決めてある**(4-2)。「運用で気をつける」は仕組みではない。
4. **ズレたときに検出できる**。定期的に正規形側と突き合わせる検証クエリを用意する。

非正規化の3つの型:

| 型 | 例 | 向いている維持手段 |
|---|---|---|
| **サマリ列(集計値)** | `Orders` に `注文合計金額` を持つ | インデックス付きビュー / トリガー / バッチ |
| **結合を減らす冗長列** | `OrderDetails` に `CategoryId` を持つ | トリガー / バッチ(または結合のまま我慢) |
| **参照頻度の高い派生値** | `明細金額 = Quantity*UnitPrice*(1-Discount)` | **計算列**(同一行から導けるので最優先) |

`dbo.SalesFact` の `Amount` 列がまさに3番目です。
`Quantity * UnitPrice * (1 - Discount)` で計算できる値をあえて持っています。
1000万行を集計するとき、**毎回 3回の乗算をしないで済む** ことと、
列ストアで **`Amount` だけを読める**([30 列ストアインデックス](30_columnstore.md))ことが効きます。

### 4-2. 整合性をどう担保するか(4つの手段)

**(a) 計算列 — 同一行から導ける値なら、これが最善**

- SQL Server が式を保持するので **ズレが原理的に起こらない**。
- 追加コストはほぼゼロ(非 PERSISTED なら格納すらしない)。
- **制約は「同じ行の中だけ」**。他の行や他のテーブルは参照できない。→ 5 節

**(b) インデックス付きビュー — 集計値なら、これが最善**

- SQL Server が **トランザクション内で自動的に維持** する。ズレない。
- 代償は **更新コスト**(元表を1行更新すると集計行も更新される)。→ 6 節

**(c) トリガー — 自由だが最後の手段**

```sql
-- 考え方だけ示す(この章では作らない)
-- CREATE TRIGGER TR_... ON dbo.OrderDetails AFTER INSERT, UPDATE, DELETE
--   → inserted / deleted を「集合として」処理する。
--     カーソルや「1行前提」のコードを書いた瞬間にバグる。
```

- **必ず集合ベースで書く**。`inserted` / `deleted` には複数行入りうる。
- 3種の DML すべてを漏れなく扱う。1つ忘れると静かにズレる。
- `MERGE`・`BULK INSERT`(既定でトリガー発火しない)・`TRUNCATE`(発火しない)の抜け道に注意。
- 実行プランに現れにくく、**遅い原因として最も見つけにくい**。使うなら覚悟を持って。

**(d) バッチ更新 — 「多少ズレてよい」なら最も安い**

- 夜間に集計テーブルを作り直す。更新パスに一切コストが乗らない。
- 代償は **鮮度**。「昨日時点の値」でよい画面にしか使えない。
- **必ず「いつ時点のデータか」を画面に出す**こと。出さないと不整合バグとして報告される。

> ⚠️ どの手段を選んでも、**正規形側が「正」で、非正規化側は「導出物」** という関係を崩さないこと。
> 導出物のほうを直接 UPDATE できてしまう設計にすると、必ずいつか矛盾します。

---

## 5. 計算列 (computed column)

### 5-1. 基本 — 式そのものを列定義にする

```sql
-- 明細金額を「式」ではなく「列」として定義する(実験用テーブルで)
DROP TABLE IF EXISTS dbo.DemoOrderLine;

CREATE TABLE dbo.DemoOrderLine
(
    OrderId   INT            NOT NULL,
    ProductId INT            NOT NULL,
    Quantity  INT            NOT NULL,
    UnitPrice DECIMAL(10, 0) NOT NULL,
    Discount  DECIMAL(4, 2)  NOT NULL CONSTRAINT DF_DemoOrderLine_Discount DEFAULT (0),
    -- ★ 計算列。定義は1箇所にしか書かれない
    LineAmount AS (Quantity * UnitPrice * (1 - Discount)),
    CONSTRAINT PK_DemoOrderLine PRIMARY KEY (OrderId, ProductId)
);

INSERT INTO dbo.DemoOrderLine (OrderId, ProductId, Quantity, UnitPrice, Discount)
SELECT OrderId, ProductId, Quantity, UnitPrice, Discount
FROM   dbo.OrderDetails;

SELECT TOP (5) OrderId, ProductId, Quantity, UnitPrice, Discount, LineAmount
FROM   dbo.DemoOrderLine
ORDER  BY OrderId, ProductId;
```

- **式の定義が1箇所に集約される**。「担当者ごとに割引の計算式が微妙に違う」事故が起きなくなる。
- `INSERT` / `UPDATE` で計算列に値を入れることは **できません**(常に導出される)。

### 5-2. PERSISTED の有無

| | 既定(非 PERSISTED) | `PERSISTED` |
|---|---|---|
| 格納 | **しない**。参照されたときに毎回計算 | **する**。行と一緒にディスクに書く |
| 行サイズ | 増えない | **増える**(7 節の IO に直結) |
| 更新コスト | なし | 元の列が変わるたびに再計算・再書き込み |
| インデックス | 決定的かつ **精密(precise)** なら可 | **不正確な式でも可** |

```sql
ALTER TABLE dbo.DemoOrderLine
    ADD LineAmountP AS (Quantity * UnitPrice * (1 - Discount)) PERSISTED;
```

### 5-3. インデックスを貼れる条件 — 推測せずに問い合わせる

計算列にインデックスを貼るには、式が **決定的 (deterministic)** で、
かつ **精密 (precise)** であるか `PERSISTED` である必要があります。
「たぶん大丈夫」ではなく **`COLUMNPROPERTY` で確認** してください。

```sql
SELECT c.name                                                            AS 計算列,
       COLUMNPROPERTY(c.object_id, c.name, 'IsDeterministic')            AS 決定的か,
       COLUMNPROPERTY(c.object_id, c.name, 'IsPrecise')                  AS 精密か,
       COLUMNPROPERTY(c.object_id, c.name, 'IsIndexable')                AS インデックス可能か,
       cc.is_persisted                                                   AS PERSISTED,
       cc.definition                                                     AS 定義
FROM   sys.computed_columns AS cc
JOIN   sys.columns          AS c
       ON c.object_id = cc.object_id AND c.column_id = cc.column_id
WHERE  cc.object_id = OBJECT_ID('dbo.DemoOrderLine');
```

- `IsDeterministic = 0` の代表例: `GETDATE()`、`NEWID()`、`FORMAT()`(カルチャ依存)、
  スタイル指定なしの `CONVERT`、照合順序に依存する一部の文字列関数。
- `IsPrecise = 0` の代表例: `FLOAT` / `REAL` が式に混ざるもの。
  → **`PERSISTED` を付ければインデックス可能になります**(計算結果を確定して保存するため)。

```sql
-- 不正確な式の例: FLOAT が混ざる
ALTER TABLE dbo.DemoOrderLine
    ADD LineAmountF AS (CAST(Quantity AS FLOAT) * UnitPrice);
-- → IsPrecise = 0, IsIndexable = 0 になる。インデックスを作ろうとすると失敗する。

-- PERSISTED にすれば貼れる
ALTER TABLE dbo.DemoOrderLine DROP COLUMN LineAmountF;
ALTER TABLE dbo.DemoOrderLine
    ADD LineAmountF AS (CAST(Quantity AS FLOAT) * UnitPrice) PERSISTED;
-- → IsIndexable = 1 になる
```

> ⚠️ 計算列を作るセッションの **SET オプション**(`ANSI_NULLS` / `QUOTED_IDENTIFIER` など)が
> 既定と違うと、インデックスが作れなかったり、後から更新が失敗したりします。
> SSMS の既定のままなら問題ありませんが、アプリの接続文字列側で変えている場合は要注意です。

### 5-4. 計算列で SARGable にする(18章の応用)

[18 インデックスと実行プラン](18_indexes_execution_plans.md) で
「`WHERE YEAR(OrderDate) = 2023` は非 SARGable」と学びました。
本来は範囲条件に書き換えるべきですが、**アプリのコードに手が入れられない**ことがあります。
そのときの武器が計算列です。

```sql
SET STATISTICS IO ON;

-- Before: 列に関数 → Clustered Index Scan、論理読み取りは数千(環境により前後する目安)
SELECT COUNT(*) FROM dbo.DemoOrders WHERE YEAR(OrderDate) = 2023;

SET STATISTICS IO OFF;
GO

-- 計算列 + インデックスを追加する
ALTER TABLE dbo.DemoOrders ADD OrderYear AS YEAR(OrderDate);   -- 決定的かつ精密なので PERSISTED 不要
GO
CREATE NONCLUSTERED INDEX IX_DemoOrders_OrderYear ON dbo.DemoOrders (OrderYear);
GO

SET STATISTICS IO ON;

-- After: ★クエリを1文字も変えていない★ のに Index Seek になる
SELECT COUNT(*) FROM dbo.DemoOrders WHERE YEAR(OrderDate) = 2023;

SET STATISTICS IO OFF;
```

**ここが肝**です。クエリは `OrderYear` という列名を **一度も書いていません**。
それでもオプティマイザは **式 `YEAR(OrderDate)` を計算列の定義と照合(expression matching)** し、
インデックスを使ってくれます。

> ⚠️ 照合されるのは **式が定義とほぼ一致する場合だけ** です。
> `YEAR(OrderDate) = 2023` は当たりますが、`DATEPART(YEAR, OrderDate) = 2023` や
> `CONVERT(CHAR(4), OrderDate, 112) = '2023'` は当たりません。
> **本命はあくまで「クエリを SARGable に書き換えること」**。計算列は
> 「書き換えられないとき」「その式が全社的に頻出するとき」の次善策です。

### 5-5. JSON への応用(22章の回収)

[22 JSON操作](22_json.md) で扱った `JSON_VALUE` は、そのまま `WHERE` に書くと毎行評価になります。
計算列にしてインデックスを貼れば、**JSON の中身でシークできる** ようになります。

```sql
DROP TABLE IF EXISTS dbo.DemoJsonOrders;

CREATE TABLE dbo.DemoJsonOrders
(
    Id      INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_DemoJsonOrders PRIMARY KEY,
    Payload NVARCHAR(MAX)     NOT NULL
        CONSTRAINT CK_DemoJsonOrders_Json CHECK (ISJSON(Payload) = 1),
    -- ★ JSON 内の値を取り出す計算列。インデックスのキーにするので短い型に CAST する
    CustomerCity AS CAST(JSON_VALUE(Payload, '$.customer.city') AS NVARCHAR(50))
);

INSERT INTO dbo.DemoJsonOrders (Payload)
VALUES (N'{"orderId":1001,"customer":{"name":"アルファ商事","city":"東京"},"amount":256000}'),
       (N'{"orderId":1003,"customer":{"name":"ガンマ物産","city":"大阪"},"amount":32000}'),
       (N'{"orderId":1005,"customer":{"name":"デルタ電子","city":"名古屋"},"amount":58000}');

CREATE NONCLUSTERED INDEX IX_DemoJsonOrders_City ON dbo.DemoJsonOrders (CustomerCity);

-- 計算列名で書いても、JSON_VALUE の式で書いても、同じインデックスが使われる
SELECT Id, CustomerCity FROM dbo.DemoJsonOrders WHERE CustomerCity = N'東京';
SELECT Id, CustomerCity FROM dbo.DemoJsonOrders
WHERE  CAST(JSON_VALUE(Payload, '$.customer.city') AS NVARCHAR(50)) = N'東京';
```

- `ISJSON`(**2016+**)の `CHECK` 制約で「JSON でないものは入らない」を保証しておくのが定石。
- **インデックスのキー列に `NVARCHAR(MAX)` は使えません**。必ず `CAST` して長さを決めます。
- とはいえ **JSON は「本当にスキーマが決まらない属性」だけに使う**こと。
  常に問い合わせる項目なら、素直に列にするほうが速くて安全です(10 節)。

---

## 6. インデックス付きビュー (indexed view)

集計値の非正規化を **SQL Server 自身に維持させる** 仕組みです。

### 6-1. 作り方と厳しい作成条件

```sql
-- インデックス付きビューは SET オプションに厳格。作成前に必ずそろえる
SET NUMERIC_ROUNDABORT OFF;
SET ANSI_NULLS, ANSI_PADDING, ANSI_WARNINGS, ARITHABORT,
    CONCAT_NULL_YIELDS_NULL, QUOTED_IDENTIFIER ON;
GO

CREATE VIEW dbo.vw_DemoProductSales
WITH SCHEMABINDING                                   -- ★ 必須
AS
SELECT od.ProductId,
       SUM(od.Quantity * od.UnitPrice * (1 - od.Discount)) AS TotalAmount,
       SUM(od.Quantity)                                    AS TotalQty,
       COUNT_BIG(*)                                        AS LineCount   -- ★ 必須
FROM   dbo.OrderDetails AS od                        -- ★ 2部構成名 (schema.table)
GROUP  BY od.ProductId;
GO

-- ★ 最初のインデックスは必ず UNIQUE CLUSTERED
CREATE UNIQUE CLUSTERED INDEX IX_vw_DemoProductSales
    ON dbo.vw_DemoProductSales (ProductId);
GO

SELECT * FROM dbo.vw_DemoProductSales ORDER BY TotalAmount DESC;
```

主な作成条件(引っかかりやすい順):

| 条件 | 補足 |
|---|---|
| `WITH SCHEMABINDING` | ベーステーブルを **構造変更できなくなる**(後述の代償) |
| すべて **2部構成名** (`dbo.OrderDetails`) | `OrderDetails` だけだとエラー |
| `GROUP BY` があるなら **`COUNT_BIG(*)` 必須** | `COUNT(*)` では不可。増分維持に行数が要るため |
| `SUM` の対象は **NULL にならない式** のみ | NULL 可の列を集計したいなら `ISNULL` などで包む |
| 最初のインデックスは **`UNIQUE CLUSTERED`** | ビューの結果が一意に定まる必要がある |
| 使えないもの | `OUTER JOIN` / `UNION` / `DISTINCT` / `TOP` / サブクエリ / CTE / `HAVING` / 非決定的関数 / `AVG`・`MIN`・`MAX`・`STDEV`・`VAR`・`COUNT(*)` |
| SET オプション | 上記6つ ON + `NUMERIC_ROUNDABORT` OFF。**参照する側の接続でも同じ設定が必要** |

> ⚠️ `AVG` が使えないのは意地悪ではなく、**増分維持できない**からです。
> 代わりに `SUM` と `COUNT_BIG(*)` を持たせ、**参照する側で割り算** します。
> `SELECT ProductId, TotalAmount / LineCount FROM ...` の形。

### 6-2. 自動マッチングと `NOEXPAND`

```sql
-- ビューの名前を一切書いていないクエリ
SELECT od.ProductId,
       SUM(od.Quantity * od.UnitPrice * (1 - od.Discount)) AS 売上
FROM   dbo.OrderDetails AS od
GROUP  BY od.ProductId;
```

- **Enterprise / Developer エディション** では、オプティマイザがこのクエリを
  **勝手にインデックス付きビューに置き換える**ことがあります(自動マッチング)。
  実行プランに `vw_DemoProductSales` が現れたら成功です。
- **Standard / Express では自動マッチングは働きません**。
  ビューを直接参照し、さらに **`WITH (NOEXPAND)` ヒントを明示** する必要があります。

```sql
-- Standard でもインデックスを使わせる書き方
SELECT ProductId, TotalAmount
FROM   dbo.vw_DemoProductSales WITH (NOEXPAND)
WHERE  ProductId = 1;
```

- `NOEXPAND` を付けないと、Standard ではビュー定義が **展開されて元表を集計し直します**
  (= インデックス付きビューを作った意味が消える)。
- 逆に `EXPAND VIEWS` クエリヒントを付けると、Enterprise でも強制的に展開できます(切り分けに便利)。

エディションの確認:

```sql
SELECT SERVERPROPERTY('Edition') AS エディション,
       SERVERPROPERTY('ProductVersion') AS バージョン;
```

### 6-3. 代償 — 更新コストとスキーマの固定

```sql
-- 元表を1行更新すると、集計行も同じトランザクション内で更新される
BEGIN TRAN;

SET STATISTICS IO ON;
UPDATE dbo.OrderDetails SET Quantity = Quantity + 1
WHERE  OrderId = 1001 AND ProductId = 1;
SET STATISTICS IO OFF;
-- → 出力に vw_DemoProductSales への書き込みが現れる

ROLLBACK;   -- 必ず戻す
```

- **書き込みが確実に重くなります**。更新が多いテーブルには向きません。
- `SCHEMABINDING` により、**ビューが参照している列は `ALTER TABLE` できません**。
  `dbo.OrderDetails.Quantity` の型を変えたくなったら、**先にビューを削除**する必要があります。
- したがってインデックス付きビューは
  **「更新が少なく、参照が多く、集計が重い」** ケース専用の道具です。

---

## 7. データ型の選択が性能を決める(この章の核心)

### 7-1. 因果関係: 行サイズ → ページあたり行数 → IO 量

[33 SQL Serverアーキテクチャ](33_architecture.md) で見たとおり、
SQL Server の IO 単位は **8KB のページ** です。ここから決定的な事実が導かれます。

```
1ページ = 8192 バイト。うちヘッダ 96 バイトを除いた約 8096 バイトにデータが入る。
        (実際は行ごとに 2 バイトのスロット配列も消費する)

  1ページあたりの行数 ≒ 8096 ÷ (行サイズ + 2)

  必要なページ数 = 行数 ÷ 1ページあたりの行数

  論理読み取り数(全件走査時) ≒ 必要なページ数
```

つまり **行を半分の太さにすれば、全件走査の IO は半分になります**。
これは「クエリの書き方」では絶対に取り返せない差です。
しかも **バッファプールに載る行数も倍**になるので、キャッシュヒット率まで改善します。

### 7-2. 実験 — 同じ情報を「太い型」と「細い型」で持つ

```sql
DROP TABLE IF EXISTS dbo.DemoRowWide;
DROP TABLE IF EXISTS dbo.DemoRowNarrow;

-- 【太い設計】とりあえず大きい型にしておいた、という設計
CREATE TABLE dbo.DemoRowWide
(
    OrderId    BIGINT        NOT NULL CONSTRAINT PK_DemoRowWide PRIMARY KEY,  -- 8 バイト
    OrderDate  DATETIME2(7)  NOT NULL,     -- 8 バイト(精度を書かないと 7 になる)
    CustomerId BIGINT        NOT NULL,     -- 8 バイト
    Status     NVARCHAR(50)  NOT NULL,     -- 実データ 2バイト×文字数 + 可変長オーバーヘッド
    Amount     FLOAT         NOT NULL,     -- 8 バイト。しかも金額に使ってはいけない(7-4)
    Note       NCHAR(100)    NOT NULL      -- ★固定長 200 バイト。中身が空でも 200 バイト
);

-- 【細い設計】必要十分な型を選んだ設計
CREATE TABLE dbo.DemoRowNarrow
(
    OrderId    INT           NOT NULL CONSTRAINT PK_DemoRowNarrow PRIMARY KEY,  -- 4 バイト
    OrderDate  DATE          NOT NULL,     -- 3 バイト
    CustomerId SMALLINT      NOT NULL,     -- 2 バイト
    StatusId   TINYINT       NOT NULL,     -- 1 バイト(コード化してマスタと結合)
    Amount     DECIMAL(9, 0) NOT NULL,     -- 5 バイト
    Note       NVARCHAR(100) NULL          -- 可変長。空なら実質ゼロ
);
GO

-- 同じ 200,000 行を両方に入れる
;WITH E1(n) AS (SELECT 1 FROM (VALUES(1),(1),(1),(1),(1),(1),(1),(1),(1),(1)) AS t(n)),
      E2(n) AS (SELECT 1 FROM E1 AS a CROSS JOIN E1 AS b),
      E4(n) AS (SELECT 1 FROM E2 AS a CROSS JOIN E2 AS b),
      Nums(n) AS (SELECT TOP (200000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
                  FROM E4 AS a CROSS JOIN E2 AS b)
INSERT INTO dbo.DemoRowWide (OrderId, OrderDate, CustomerId, Status, Amount, Note)
SELECT n, DATEADD(DAY, n % 3653, '2015-01-01'), n % 1000 + 1, N'完了', 12345.0, N''
FROM   Nums;

;WITH E1(n) AS (SELECT 1 FROM (VALUES(1),(1),(1),(1),(1),(1),(1),(1),(1),(1)) AS t(n)),
      E2(n) AS (SELECT 1 FROM E1 AS a CROSS JOIN E1 AS b),
      E4(n) AS (SELECT 1 FROM E2 AS a CROSS JOIN E2 AS b),
      Nums(n) AS (SELECT TOP (200000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
                  FROM E4 AS a CROSS JOIN E2 AS b)
INSERT INTO dbo.DemoRowNarrow (OrderId, OrderDate, CustomerId, StatusId, Amount, Note)
SELECT n, DATEADD(DAY, n % 3653, '2015-01-01'), n % 1000 + 1, 1, 12345, NULL
FROM   Nums;
GO
```

**測ります**。推測しないこと。

```sql
-- 平均レコードサイズとページ数を比較する
SELECT OBJECT_NAME(ps.object_id)      AS テーブル,
       ps.page_count                  AS ページ数,
       ps.record_count                AS 行数,
       ps.avg_record_size_in_bytes    AS 平均行サイズ,
       ps.page_count * 8              AS 使用KB
FROM   sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID('dbo.DemoRowWide'),  1, NULL, 'DETAILED') AS ps
WHERE  ps.index_level = 0
UNION ALL
SELECT OBJECT_NAME(ps.object_id), ps.page_count, ps.record_count,
       ps.avg_record_size_in_bytes, ps.page_count * 8
FROM   sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID('dbo.DemoRowNarrow'), 1, NULL, 'DETAILED') AS ps
WHERE  ps.index_level = 0;
```

```sql
-- 全件走査の論理読み取り数を比較する
SET STATISTICS IO ON;
SELECT COUNT(*) FROM dbo.DemoRowWide;
SELECT COUNT(*) FROM dbo.DemoRowNarrow;
SET STATISTICS IO OFF;
```

環境により前後しますが、目安として **太い側の平均行サイズは細い側の 3〜4 倍**、
ページ数と論理読み取り数もほぼ同じ比率になります。

> ⚠️ ここで効いているのは **`NCHAR(100)` が中身の有無にかかわらず 200 バイト消費する** ことです。
> 「とりあえず余裕を持って」と `NCHAR` / `CHAR` を長く取ると、**空でも満額課金**されます。
> 逆に「必ず埋まる短い固定長」(郵便番号、都道府県コード、`CHAR(1)` のフラグ)なら
> 可変長のオーバーヘッド(列あたり2バイト)が無いぶん固定長が有利です。

### 7-3. 型の選び方(実務の判断基準)

**整数**

| 型 | サイズ | 範囲 | 使いどころ |
|---|---|---|---|
| `TINYINT` | 1 | 0〜255 | 区分コード、ステータス |
| `SMALLINT` | 2 | ±32,767 | 小規模マスタの ID |
| `INT` | 4 | 約 ±21億 | **既定の選択**。ID の大半はこれで足りる |
| `BIGINT` | 8 | 約 ±922京 | 本当に21億行を超えるとき **だけ** |

- **`BIGINT` を「念のため」で選ばないこと**。主キーを `BIGINT` にすると、
  **そのテーブルの全非クラスタ化インデックスの葉に 8 バイトが乗ります**(2-2 の構造。18章)。
  10本あれば 10箇所で太る。
- 逆に「21億を超える可能性が本当にある」なら、最初から `BIGINT` に。
  後から `INT → BIGINT` に変えるのは全表・全インデックスの再構築で、大規模テーブルでは事実上不可能です。
- `dbo.SalesFact.SaleId` が `BIGINT` なのは **1000万行、将来さらに増える前提のファクト表** だから。
  `dbo.OrdersBig.OrderId` が `INT` なのは 100 万行だから。**用途に応じて分けている**わけです。

**小数・金額**

`DECIMAL(p, s)` の格納サイズは **精度 `p` だけ** で決まります(位取り `s` は無関係)。

| 精度 p | サイズ |
|---|---|
| 1〜9 | **5 バイト** |
| 10〜19 | **9 バイト** |
| 20〜28 | 13 バイト |
| 29〜38 | 17 バイト |

- **`p = 9` と `p = 10` の間に崖があります**。`DECIMAL(10,0)` は 9 バイト、
  `DECIMAL(9,0)`(最大 999,999,999)なら 5 バイト。1000万行なら **40MB の差**。
- サンプルDB の `UnitPrice DECIMAL(10, 0)` は、この崖のすぐ右側。
  「10桁必要か?」を検討する価値がある、という良い教材です。
- `MONEY` / `SMALLMONEY` は位取り4桁固定。除算で丸め誤差が出るため、**新規設計では `DECIMAL` を推奨**。

**文字列**

| 型 | 1文字あたり | 特徴 |
|---|---|---|
| `VARCHAR(n)` | 1 バイト | ASCII のみ。**行あたり2バイト+列あたり2バイトのオーバーヘッド** |
| `NVARCHAR(n)` | 2 バイト | Unicode。日本語を扱うなら基本これ |
| `CHAR(n)` / `NCHAR(n)` | 固定 | 常に n(または 2n)バイト。短く必ず埋まる列だけ |

- **日本語が1文字でも入りうるなら `NVARCHAR`**。`VARCHAR` に入れると文字化けします。
- 商品コード・郵便番号・ISO 通貨コードなど **ASCII しか入らないと保証できる列** は
  `VARCHAR` / `CHAR` にしてよい。半分のサイズになります。
- **SQL Server 2019 以降** は UTF-8 照合順序(`..._UTF8`)で `VARCHAR` に Unicode を格納できます。
  ただし **日本語は UTF-8 では1文字3バイト** なので、日本語主体の列では
  `NVARCHAR`(2バイト)より **かえって太ります**。英数字主体の列でだけ検討してください。
- `n` は「最悪ケース」ではなく **業務上の上限** に合わせる。
  可変長なので `NVARCHAR(4000)` にしても実データが短ければ格納サイズは同じですが、
  **オプティマイザはメモリ確保量を「宣言長の半分」で見積もる**ため、
  過剰な宣言長は **メモリ許可の過大要求 → 並列度低下・待ち** を招きます。

**日付・時刻**

| 型 | サイズ | 精度 |
|---|---|---|
| `DATE` | **3** | 日 |
| `SMALLDATETIME` | 4 | 分 |
| `DATETIME2(0)`〜`(2)` | **6** | 秒〜1/100秒 |
| `DATETIME2(3)`〜`(4)` | 7 | ミリ秒 |
| `DATETIME2(5)`〜`(7)` | 8 | 〜100ナノ秒 |
| `DATETIME` | 8 | 約 3.33ms(丸められる) |
| `DATETIMEOFFSET(n)` | 8〜10 | 上記+タイムゾーンオフセット |

- **時刻が要らないなら `DATE`**。サンプルDB の `OrderDate` / `HireDate` はこれ。
  `DATETIME` にすると 8 バイト、**2.7倍**です。
- **`DATETIME2` は精度を必ず書く**。`DATETIME2` とだけ書くと `(7)` = 8 バイトになります。
  秒までで十分なら `DATETIME2(0)` で 6 バイト。
- `DATETIME` は精度が 3.33ms 刻みで丸められるため、`23:59:59.997` の罠があります。
  **新規設計では `DATETIME2` を使う**。
- グローバルなシステムなら `DATETIMEOFFSET` か「UTC で保存し表示時に変換」を選ぶ。
  **ローカル時刻をオフセット無しで保存するのが最悪**(夏時間で1年に1回必ず壊れる)。

### 7-4. 避けるべき型

**(a) `FLOAT` / `REAL` で金額を持つ — 絶対にやってはいけない**

```sql
DECLARE @f FLOAT = 0.1, @g FLOAT = 0.2;
SELECT CASE WHEN @f + @g = 0.3 THEN N'一致' ELSE N'不一致' END AS 浮動小数点,
       @f + @g AS 計算結果;

DECLARE @d DECIMAL(10,2) = 0.1, @e DECIMAL(10,2) = 0.2;
SELECT CASE WHEN @d + @e = 0.3 THEN N'一致' ELSE N'不一致' END AS 10進数;
```

- `FLOAT` は **2進の近似値** です。`0.1` を正確に表現できません。
- 合計が1円合わない、`WHERE Amount = 1000` が引っかからない、といった
  **再現性の低いバグ**の温床になります。
- 金額・数量・率は必ず **`DECIMAL`**。`FLOAT` は測定値(温度・座標・センサー値)専用と考えてください。

**(b) 過剰な `NVARCHAR(MAX)`**

- **インデックスのキー列にできません**(`INCLUDE` には入れられます)。
- 8000 バイトを超えると **行外(LOB)に格納**され、参照のたびに追加の IO が発生します。
- 行内に収まっていても、**オプティマイザのメモリ見積もりを大きく歪めます**。
- 「長さが読めないから MAX」ではなく、**業務上の上限を決めて `NVARCHAR(4000)` 以内に収める**。
  本当に長文(記事本文・添付 JSON)だけ MAX を使い、できれば **別テーブルに分離** します。

**(c) `TEXT` / `NTEXT` / `IMAGE` — 非推奨。使ってはいけない**

- Microsoft が **将来のバージョンで削除予定** と明言している旧型。
- `=` で比較できない、`LIKE` に制限がある、多くの文字列関数が使えない、
  変数に代入できないなど、**扱いが特殊で例外だらけ**。
- 置き換え先: `TEXT → VARCHAR(MAX)`、`NTEXT → NVARCHAR(MAX)`、`IMAGE → VARBINARY(MAX)`。
- 既存システムで見つけたら、移行計画を立てる対象です。

**(d) `SQL_VARIANT`**

- 「何でも入る列」。**型の恩恵をすべて捨てる**ことになります(10 節の EAV と同じ問題)。
- インデックスは張れますが比較規則が複雑で、多くの関数が直接使えません。避けるのが無難です。

### 7-5. 暗黙の型変換がインデックスを無効化する(18章の回収)

型の選択ミスは **サイズだけでなくプランも壊します**。

```sql
DROP TABLE IF EXISTS dbo.DemoTypeMismatch;

CREATE TABLE dbo.DemoTypeMismatch
(
    Id       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_DemoTypeMismatch PRIMARY KEY,
    OrderNo  VARCHAR(20)       NOT NULL,   -- ★ VARCHAR で定義されている
    Amount   DECIMAL(9, 0)     NOT NULL
);

;WITH E1(n) AS (SELECT 1 FROM (VALUES(1),(1),(1),(1),(1),(1),(1),(1),(1),(1)) AS t(n)),
      E2(n) AS (SELECT 1 FROM E1 AS a CROSS JOIN E1 AS b),
      E4(n) AS (SELECT 1 FROM E2 AS a CROSS JOIN E2 AS b),
      Nums(n) AS (SELECT TOP (200000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
                  FROM E4 AS a CROSS JOIN E2 AS b)
INSERT INTO dbo.DemoTypeMismatch (OrderNo, Amount)
SELECT RIGHT('0000000' + CAST(n AS VARCHAR(10)), 8), n % 100000
FROM   Nums;

CREATE NONCLUSTERED INDEX IX_DemoTypeMismatch_OrderNo ON dbo.DemoTypeMismatch (OrderNo);
GO

SET STATISTICS IO ON;

-- ✗ NVARCHAR リテラルで比較 → 型の優先順位で ★列側★ が NVARCHAR に変換される
--    → プランに CONVERT_IMPLICIT と警告アイコンが出て Index Scan になる
SELECT Id, Amount FROM dbo.DemoTypeMismatch WHERE OrderNo = N'00012345';

-- ○ 列と同じ型のリテラルで比較 → Index Seek
SELECT Id, Amount FROM dbo.DemoTypeMismatch WHERE OrderNo = '00012345';

SET STATISTICS IO OFF;
```

**なぜこうなるのか**: SQL Server には **データ型の優先順位** があり、
`NVARCHAR` は `VARCHAR` より優先度が高い。異なる型を比較すると **低いほうが高いほうに変換されます**。
`VARCHAR` 列 = `NVARCHAR` リテラルでは **列のほうが全行変換** され、
インデックスの並び順が使えなくなります(= 18章 4 節の「列を関数で包む」のと同じこと)。

- 逆向き(`NVARCHAR` 列 = `VARCHAR` リテラル)は **リテラル側が昇格** するので Seek は保てます。
- .NET の既定は `NVARCHAR` で送るため、**`VARCHAR` 列を持つテーブルでこの事故が非常に多い**。
  だからこそ **「日本語を扱うなら列も `NVARCHAR` にそろえる」** のが本プロジェクトの方針です。
- 数値も同じ。`INT` 列を `WHERE Id = '100'` と文字列で比較しても、
  この場合は数値の優先度が高いので **リテラル側**が変換され問題ありません。
  しかし `VARCHAR` 列に数値を比較すると **列側**が変換されて Scan になります。

**現在キャッシュされているプランから、この問題を一括で探すこともできます。**

```sql
-- プラン XML に CONVERT_IMPLICIT を含むクエリを洗い出す(調査用。本番では負荷に注意)
SELECT TOP (20)
       DB_NAME(qp.dbid)              AS DB名,
       qs.execution_count            AS 実行回数,
       qs.total_logical_reads        AS 累計論理読み取り,
       SUBSTRING(qt.text, (qs.statement_start_offset/2) + 1,
                 ((CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(qt.text)
                        ELSE qs.statement_end_offset END - qs.statement_start_offset)/2) + 1) AS クエリ
FROM   sys.dm_exec_query_stats AS qs
CROSS  APPLY sys.dm_exec_sql_text(qs.plan_handle)   AS qt
CROSS  APPLY sys.dm_exec_query_plan(qs.plan_handle) AS qp
WHERE  CAST(qp.query_plan AS NVARCHAR(MAX)) LIKE N'%CONVERT_IMPLICIT%'
ORDER  BY qs.total_logical_reads DESC;
```

---

## 8. キー設計

### 8-1. 代理キー (surrogate key) と自然キー (natural key)

| | 自然キー | 代理キー |
|---|---|---|
| 例 | 商品コード、メールアドレス、`(注文番号, 行番号)` | `IDENTITY` の連番、`SEQUENCE`、GUID |
| 長所 | 業務上の意味がある。結合せずに読める | **狭い・不変・一意が保証しやすい** |
| 短所 | **業務ルールが変わると値が変わる**。太くなりがち | 業務的な意味がない。別途一意制約が要る |

判断の指針:

- **主キーは代理キーにするのが既定**。理由は「**業務は必ず変わる**」から。
  「商品コードは絶対に変わりません」と言われた列は、3年後に必ず変わります。
  主キーが変わると **全子テーブルの外部キーを連鎖更新** することになります。
- ただし **代理キーを付けたら、自然キーには必ず `UNIQUE` 制約を付ける**。
  これを忘れると「同じ商品コードの行が2行ある」というデータ破壊が起きます。
  代理キーは自然キーの代わりではなく、**追加**です。
- **交差テーブル(多対多)は自然キーの複合主キーで十分**なことが多い。
  `dbo.OrderDetails` の `PRIMARY KEY (OrderId, ProductId)` がまさにこれで、
  **同じ注文に同じ商品が2行入らない** というビジネスルールを主キーだけで表現しています。
  ここに `OrderDetailId` を足すと、そのルールが消えてしまいます(足すなら別途 `UNIQUE` が必要)。

### 8-2. クラスター化インデックスキーの選び方

**クラスター化インデックスの葉 = テーブル本体そのもの**(18章 2-1)であり、さらに
**すべての非クラスタ化インデックスの葉に、クラスター化キーの値がコピーされます**。
つまり **クラスター化キーの選択は、そのテーブルの全インデックスに波及** します。

望ましい性質は4つ。頭文字で覚えます。

| 性質 | 理由 |
|---|---|
| **狭い (narrow)** | 全非クラスタ化インデックスに複製されるため。1バイトの差が全体に効く |
| **一意 (unique)** | 一意でないと SQL Server が内部で4バイトの uniquifier を付け足す(= 太る) |
| **不変 (static)** | キーが変わる = 行が物理的に移動し、全非クラスタ化インデックスも更新される |
| **増加 (ever-increasing)** | 常に末尾に追記される → **ページ分割が起きない**。断片化しない |

`dbo.Orders.OrderId`、`dbo.OrdersBig.OrderId`、`dbo.SalesFact.SaleId` はすべてこの4条件を満たしています。

> ⚠️ **主キー = クラスター化インデックス、は SQL Server の既定にすぎません**。
> `PRIMARY KEY NONCLUSTERED` と書けば分離できます。
> 例えば「主キーは GUID だが、クラスター化キーは連番」という設計は有効な選択肢です。

> ⚠️ 「常に増加」には副作用もあります。**末尾のページに挿入が集中**するため、
> 超高頻度の書き込みでは **ラッチ競合(last page insert contention、`PAGELATCH_EX`)** が起きます
> ([23 待機統計](23_wait_statistics.md))。その場合の対処が
> [32 インメモリOLTP](32_in_memory_oltp.md) や `OPTIMIZE_FOR_SEQUENTIAL_KEY`(**2019+**)です。
> ただしこれは **数万 TPS 級の話**。通常はまず「増加するキー」を選んでください。

### 8-3. GUID をクラスター化キーにすると何が起きるか — 測る

```sql
DROP TABLE IF EXISTS dbo.DemoKeyGuid;
DROP TABLE IF EXISTS dbo.DemoKeySeqGuid;
DROP TABLE IF EXISTS dbo.DemoKeyInt;

-- ① ランダムな GUID をクラスター化キーにする
CREATE TABLE dbo.DemoKeyGuid
(
    Id     UNIQUEIDENTIFIER NOT NULL
           CONSTRAINT DF_DemoKeyGuid_Id DEFAULT (NEWID())
           CONSTRAINT PK_DemoKeyGuid PRIMARY KEY CLUSTERED,
    Filler CHAR(200)        NOT NULL
);

-- ② NEWSEQUENTIALID() で単調増加する GUID にする
CREATE TABLE dbo.DemoKeySeqGuid
(
    Id     UNIQUEIDENTIFIER NOT NULL
           CONSTRAINT DF_DemoKeySeqGuid_Id DEFAULT (NEWSEQUENTIALID())
           CONSTRAINT PK_DemoKeySeqGuid PRIMARY KEY CLUSTERED,
    Filler CHAR(200)        NOT NULL
);

-- ③ IDENTITY の INT
CREATE TABLE dbo.DemoKeyInt
(
    Id     INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_DemoKeyInt PRIMARY KEY CLUSTERED,
    Filler CHAR(200)         NOT NULL
);
GO

-- 3つとも同じ 100,000 行を入れる
;WITH E1(n) AS (SELECT 1 FROM (VALUES(1),(1),(1),(1),(1),(1),(1),(1),(1),(1)) AS t(n)),
      E2(n) AS (SELECT 1 FROM E1 AS a CROSS JOIN E1 AS b),
      E4(n) AS (SELECT 1 FROM E2 AS a CROSS JOIN E2 AS b),
      Nums(n) AS (SELECT TOP (100000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
                  FROM E4 AS a CROSS JOIN E2 AS b)
INSERT INTO dbo.DemoKeyGuid (Filler) SELECT 'x' FROM Nums;

;WITH E1(n) AS (SELECT 1 FROM (VALUES(1),(1),(1),(1),(1),(1),(1),(1),(1),(1)) AS t(n)),
      E2(n) AS (SELECT 1 FROM E1 AS a CROSS JOIN E1 AS b),
      E4(n) AS (SELECT 1 FROM E2 AS a CROSS JOIN E2 AS b),
      Nums(n) AS (SELECT TOP (100000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
                  FROM E4 AS a CROSS JOIN E2 AS b)
INSERT INTO dbo.DemoKeySeqGuid (Filler) SELECT 'x' FROM Nums;

;WITH E1(n) AS (SELECT 1 FROM (VALUES(1),(1),(1),(1),(1),(1),(1),(1),(1),(1)) AS t(n)),
      E2(n) AS (SELECT 1 FROM E1 AS a CROSS JOIN E1 AS b),
      E4(n) AS (SELECT 1 FROM E2 AS a CROSS JOIN E2 AS b),
      Nums(n) AS (SELECT TOP (100000) ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
                  FROM E4 AS a CROSS JOIN E2 AS b)
INSERT INTO dbo.DemoKeyInt (Filler) SELECT 'x' FROM Nums;
GO

-- 断片化率・ページ充填率・ページ数を比較する
SELECT OBJECT_NAME(ps.object_id)          AS テーブル,
       ps.page_count                      AS ページ数,
       ps.avg_fragmentation_in_percent    AS 断片化率,
       ps.avg_page_space_used_in_percent  AS ページ充填率,
       ps.avg_record_size_in_bytes        AS 平均行サイズ
FROM  (SELECT * FROM sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID('dbo.DemoKeyGuid'),    1, NULL, 'DETAILED')
       UNION ALL
       SELECT * FROM sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID('dbo.DemoKeySeqGuid'), 1, NULL, 'DETAILED')
       UNION ALL
       SELECT * FROM sys.dm_db_index_physical_stats(DB_ID(), OBJECT_ID('dbo.DemoKeyInt'),     1, NULL, 'DETAILED')) AS ps
WHERE  ps.index_level = 0
ORDER  BY 断片化率 DESC;
```

**何が起きているか**(数値は環境により前後する目安):

| テーブル | 断片化率 | ページ充填率 | 理由 |
|---|---|---|---|
| `DemoKeyGuid` | **95〜99%** | **約 70%** | 挿入位置がランダム → **ページ分割が起き続ける** |
| `DemoKeySeqGuid` | 数% 以下 | 約 99% | 末尾に追記される |
| `DemoKeyInt` | 数% 以下 | 約 99% | 末尾に追記される。しかもキーが 4 バイト |

- **ページ分割 (page split)**: 挿入先のページに空きがないと、SQL Server はページを新規に確保し、
  **既存の行の約半分を移動** させます。これにより
  ①トランザクションログが増える ②充填率が 50〜70% に落ちる
  ③論理的な順序と物理的な順序がずれる(断片化)= **先読みが効かなくなる**。
- 充填率 70% ということは、**同じデータを読むのに 1.4 倍のページを読む** ということ。IO が 1.4 倍です。
- さらに GUID は **16 バイト**。`INT`(4 バイト)の 4 倍で、
  この差が **全非クラスタ化インデックスに複製** されます。

**では GUID は使ってはいけないのか?** 使ってよい場面はあります。

- 複数拠点・オフライン端末で **サーバーに問い合わせずに ID を採番したい**。
- 複数DBのデータをマージする(ID 衝突を避けたい)。
- ID から件数を推測されたくない(`/order/1002` から `/order/1003` を推測させない)。

そのときの実務的な打ち手:

1. **`NEWSEQUENTIALID()` を既定値にする**(上の実験どおり断片化が消える)。
   ただし **サーバー再起動で系列が振り出しに戻る** ため、完全な単調増加ではありません。
   また **値が推測可能**になるので、セキュリティ目的の GUID には使えません。
2. **GUID は主キーにするが、クラスター化キーは別に持つ**。
   ```sql
   -- 考え方: PRIMARY KEY NONCLUSTERED (RowGuid) + CLUSTERED INDEX (連番)
   ```
   これが「両取り」の定石です。
3. アプリ側で **ソート可能な GUID**(いわゆる COMB / ULID)を生成する。

> ⚠️ 断片化した既存テーブルの直し方は `ALTER INDEX ... REORGANIZE`(30%未満)/
> `REBUILD`(30%以上)ですが、**GUID をクラスター化キーにしている限り、直してもすぐ元に戻ります**。
> 断片化は症状であって原因ではありません。**原因はキー設計**です。

### 8-4. `IDENTITY` と `SEQUENCE` の使い分け

```sql
DROP SEQUENCE IF EXISTS dbo.DemoOrderNumberSeq;

CREATE SEQUENCE dbo.DemoOrderNumberSeq
    AS INT
    START WITH 1001
    INCREMENT BY 1
    MINVALUE 1
    NO MAXVALUE
    CACHE 50;          -- 50個ずつメモリに確保する(速いが、再起動で未使用分が飛ぶ)
GO

-- ★ INSERT しなくても次の値を取得できる
DECLARE @next INT = NEXT VALUE FOR dbo.DemoOrderNumberSeq;
SELECT @next AS 採番された番号;

-- 現在の状態を確認する
SELECT name, current_value, increment, cache_size, is_exhausted
FROM   sys.sequences
WHERE  name = N'DemoOrderNumberSeq';
```

| | `IDENTITY` | `SEQUENCE`(**2012+**) |
|---|---|---|
| 所属 | **列に属する** | **DB に属する独立オブジェクト** |
| 事前採番 | できない(INSERT して `SCOPE_IDENTITY()`) | **`NEXT VALUE FOR` で先に取れる** |
| 複数テーブル共有 | 不可 | **可能**(伝票番号を注文・見積で共通採番など) |
| 値の指定 | `SET IDENTITY_INSERT ON` が必要 | 普通の列なのでそのまま入れられる |
| 循環 | 不可 | `CYCLE` で可能 |
| リセット | `DBCC CHECKIDENT` | `ALTER SEQUENCE ... RESTART WITH` |
| 並び順制御 | 不可 | `OVER (ORDER BY ...)` と併用できる |

**`SEQUENCE` を選ぶ場面**:

- 親子を **同一トランザクション内で先に採番して両方に埋めたい**(往復を1回減らせる)。
- **複数テーブルで通し番号** を共有したい。
- 採番ロジックをアプリではなく **DB に集約** したい。

> ⚠️ **どちらも「連番に穴が開かないこと」は保証しません**。
> ロールバックした値は返却されず、`CACHE` 分は再起動で失われます。
> 「請求書番号は絶対に連続」のような **法的要件がある番号を IDENTITY/SEQUENCE で作ってはいけません**。
> その場合は専用の採番テーブルを `UPDLOCK` で排他制御して発行します(スループットは犠牲になります)。

> ⚠️ `IDENTITY` は **SQL Server 2012 以降、サービス再起動後に値が 1000 飛ぶ** ことがあります
> (`INT` なら 1000、`BIGINT` なら 10000)。これはキャッシュの仕様です。
> 気になる場合は `ALTER DATABASE SCOPED CONFIGURATION SET IDENTITY_CACHE = OFF;`(**2017+**)。
> **ただし挿入性能が落ちます**。元に戻すには `= ON`。
> そもそも「連番に穴が開いてはいけない設計」になっていないかを先に疑ってください。

---

## 9. 制約はドキュメントであり、**性能情報でもある**

多くの人が「制約 = データを守るもの」としか思っていません。
実は制約は **オプティマイザに渡す前提知識** でもあります。

### 9-1. 5つの制約が伝えている情報

| 制約 | データを守る役割 | **オプティマイザに伝わる情報** |
|---|---|---|
| `PRIMARY KEY` | 一意かつ NULL 不可 | 行数の上限、重複排除が不要、結合が1対1と分かる |
| `UNIQUE` | 一意 | 同上。`DISTINCT` / `GROUP BY` の省略ができる |
| `FOREIGN KEY` | 参照先が存在する | **結合しても行が増えない/減らない** → **結合の除去** |
| `CHECK` | 値の範囲 | **矛盾する述語を検出** → テーブルアクセスの除去 |
| `NOT NULL` | NULL 不可 | NULL 考慮の分岐が不要。`NOT IN` の落とし穴が消える |

### 9-2. 実験 — 結合の除去 (join elimination)

```sql
DROP TABLE IF EXISTS dbo.DemoOrderHead;
DROP TABLE IF EXISTS dbo.DemoCustomer;

CREATE TABLE dbo.DemoCustomer
(
    CustomerId   INT           NOT NULL CONSTRAINT PK_DemoCustomer PRIMARY KEY,
    CustomerName NVARCHAR(100) NOT NULL
);

CREATE TABLE dbo.DemoOrderHead
(
    OrderId    INT  NOT NULL CONSTRAINT PK_DemoOrderHead PRIMARY KEY,
    CustomerId INT  NOT NULL,                        -- ★ NOT NULL であることが重要
    OrderDate  DATE NOT NULL,
    Amount     DECIMAL(9, 0) NOT NULL
        CONSTRAINT CK_DemoOrderHead_Amount CHECK (Amount >= 0)   -- ★ 後で使う
);

INSERT INTO dbo.DemoCustomer (CustomerId, CustomerName)
SELECT CustomerId, CustomerName FROM dbo.Customers;

INSERT INTO dbo.DemoOrderHead (OrderId, CustomerId, OrderDate, Amount)
SELECT o.OrderId, o.CustomerId, o.OrderDate, 10000
FROM   dbo.Orders AS o;
GO

-- (A) 外部キーが無い状態で実行 → プランには DemoCustomer が現れる
SELECT h.OrderId, h.OrderDate
FROM   dbo.DemoOrderHead AS h
JOIN   dbo.DemoCustomer  AS c ON c.CustomerId = h.CustomerId;
GO

-- 信頼された外部キーを追加する(WITH CHECK が既定。既存データを全件検証する)
ALTER TABLE dbo.DemoOrderHead WITH CHECK
    ADD CONSTRAINT FK_DemoOrderHead_DemoCustomer
    FOREIGN KEY (CustomerId) REFERENCES dbo.DemoCustomer (CustomerId);
GO

-- (B) まったく同じクエリ → ★プランから DemoCustomer へのアクセスが消える★
SELECT h.OrderId, h.OrderDate
FROM   dbo.DemoOrderHead AS h
JOIN   dbo.DemoCustomer  AS c ON c.CustomerId = h.CustomerId;
```

**なぜ消せるのか**: オプティマイザはこう推論しています。

1. `CustomerId` は `NOT NULL` なので、必ず何らかの値がある。
2. **信頼された** 外部キーがあるので、その値は `DemoCustomer` に **必ず1行存在する**。
3. `PRIMARY KEY` があるので **2行以上ではありえない**。
4. `SELECT` に `DemoCustomer` の列が1つも無い。
5. → **この結合は行数を変えない。読む意味がない。消してよい**。

これは机上の話ではありません。実務では
**「ビューが 10 テーブルを結合しているが、画面はそのうち3つの列しか使わない」**
という状況が頻繁に起こります。制約が正しく張ってあれば、
**残り7テーブルへのアクセスがプランから丸ごと消えます**。張っていなければ全部読みます。

### 9-3. 実験 — 述語の単純化(矛盾の検出)

```sql
-- CK_DemoOrderHead_Amount で Amount >= 0 が保証されている
SELECT COUNT(*) FROM dbo.DemoOrderHead WHERE Amount < 0;
```

- 実行プランを見てください。**テーブルへのアクセスが存在しない** はずです
  (`Constant Scan` だけ、または「テーブルにアクセスしない」形のプラン)。
- オプティマイザは `Amount >= 0` と `Amount < 0` が **同時に成り立たない** ことを見抜き、
  **1ページも読まずに 0 を返しています**。
- これはパーティション排除([31 パーティショニング](31_partitioning.md))や、
  「年度ごとに分けたテーブルを `UNION ALL` するビュー」の設計でも同じ原理が働きます。
  各テーブルに `CHECK (OrderDate >= '2023-01-01' AND OrderDate < '2024-01-01')` を付けておけば、
  **2023年を検索したときに他年度のテーブルを読まなくなります**。

### 9-4. 「信頼されない制約」の罠 — 多くの人が知らない落とし穴

制約は **付いているだけでは足りません**。**信頼されている (trusted)** 必要があります。

```sql
-- 外部キーをいったん外し、今度は WITH NOCHECK で付け直す
ALTER TABLE dbo.DemoOrderHead DROP CONSTRAINT FK_DemoOrderHead_DemoCustomer;

ALTER TABLE dbo.DemoOrderHead WITH NOCHECK          -- ★ 既存データを検証しない
    ADD CONSTRAINT FK_DemoOrderHead_DemoCustomer
    FOREIGN KEY (CustomerId) REFERENCES dbo.DemoCustomer (CustomerId);
GO

-- 状態を確認する
SELECT name AS 制約名, is_not_trusted AS 信頼されていない, is_disabled AS 無効
FROM   sys.foreign_keys
WHERE  parent_object_id = OBJECT_ID('dbo.DemoOrderHead');
-- → is_not_trusted = 1

-- 9-2 (B) とまったく同じクエリを実行 → ★結合が消えなくなる★
SELECT h.OrderId, h.OrderDate
FROM   dbo.DemoOrderHead AS h
JOIN   dbo.DemoCustomer  AS c ON c.CustomerId = h.CustomerId;
```

**何が起きたか**: `WITH NOCHECK` は「**既存データは検証しない**」という指定です。
SQL Server は「この制約は今後の変更には効くが、**既にあるデータが守っているとは限らない**」
と判断し、`is_not_trusted = 1` にします。信頼できない前提は **最適化には使えません**。

**制約は生きているのに、性能上の価値だけが失われる**。しかもエラーも警告も出ない。
これが「多くの人が気づかない」理由です。

**信頼状態に戻す**:

```sql
-- WITH CHECK CHECK CONSTRAINT ← CHECK が2回出るのは打ち間違いではない
--   1つ目の WITH CHECK = 「これから全件検証する」
--   2つ目の CHECK CONSTRAINT = 「この制約を有効にする」
ALTER TABLE dbo.DemoOrderHead
    WITH CHECK CHECK CONSTRAINT FK_DemoOrderHead_DemoCustomer;

SELECT name, is_not_trusted, is_disabled
FROM   sys.foreign_keys
WHERE  parent_object_id = OBJECT_ID('dbo.DemoOrderHead');
-- → is_not_trusted = 0 に戻る。結合の除去も復活する

-- そのテーブルの全制約をまとめて信頼状態に戻す
-- ALTER TABLE dbo.DemoOrderHead WITH CHECK CHECK CONSTRAINT ALL;
```

**信頼されない制約が生まれる典型的な経路**:

1. 大量ロードの前に `ALTER TABLE ... NOCHECK CONSTRAINT ALL` して、**戻すのを忘れる**。
2. データ移行時に `WITH NOCHECK` で制約を付けて「あとで直そう」と思ったまま忘れる。
3. `BULK INSERT` / `bcp` を既定オプション(制約チェックなし)で実行する。

**データベース全体を点検するクエリ**(現場で最初に流す価値があります):

```sql
SELECT N'FOREIGN KEY' AS 種別,
       OBJECT_SCHEMA_NAME(parent_object_id) + N'.' + OBJECT_NAME(parent_object_id) AS テーブル,
       name AS 制約名, is_not_trusted AS 信頼されていない, is_disabled AS 無効
FROM   sys.foreign_keys
WHERE  is_not_trusted = 1 OR is_disabled = 1
UNION ALL
SELECT N'CHECK',
       OBJECT_SCHEMA_NAME(parent_object_id) + N'.' + OBJECT_NAME(parent_object_id),
       name, is_not_trusted, is_disabled
FROM   sys.check_constraints
WHERE  is_not_trusted = 1 OR is_disabled = 1
ORDER  BY 種別, テーブル;
```

> ⚠️ `is_disabled = 1`(`NOCHECK CONSTRAINT` で無効化)は **もっと危険**です。
> 制約が **まったく効いていない** ので、参照先の無い行が入ってしまいます。
> 有効化するときは必ず `WITH CHECK` を付けること。付けないと **無効なデータを抱えたまま
> 信頼されない状態で有効化** されます。

---

## 10. スキーマ設計のアンチパターン

### 10-1. EAV (Entity-Attribute-Value)

```sql
DROP TABLE IF EXISTS dbo.DemoProductAttr;

CREATE TABLE dbo.DemoProductAttr
(
    ProductId INT           NOT NULL,
    AttrName  NVARCHAR(50)  NOT NULL,
    AttrValue NVARCHAR(200) NULL,          -- ★ 何でも入る列
    CONSTRAINT PK_DemoProductAttr PRIMARY KEY (ProductId, AttrName)
);

INSERT INTO dbo.DemoProductAttr (ProductId, AttrName, AttrValue)
VALUES (1, N'色',     N'シルバー'),
       (1, N'重量kg', N'1.4'),
       (1, N'保証年', N'3'),
       (4, N'色',     N'ブラック'),
       (4, N'重量kg', N'6.2'),
       (4, N'解像度', N'3840x2160');
```

「列を追加しなくても属性を増やせる」という魅力があります。しかし:

- **型が効かない**。`重量kg` に `N'約1.4'` と書かれても止められない。
  数値として集計しようとした瞬間に変換エラーで落ちます。
- **`NOT NULL` も `CHECK` も `FOREIGN KEY` も書けない**。整合性の担保をすべてアプリ任せにする。
- **横持ちに戻すのが高い**。1商品の5属性を取るのに5回の自己結合か `PIVOT`([10 PIVOT/UNPIVOT](10_pivot_unpivot.md))が必要。
  属性が増えるほど結合が増える。
- **統計情報が役に立たない**。`AttrName` ごとに `AttrValue` の分布はまったく違うのに、
  オプティマイザには1つの列にしか見えない → 推定を大きく外す([27 統計情報](27_statistics_cardinality.md))。
- **行数が爆発する**。20列のテーブルが20倍の行数になる。

```sql
-- 「色がシルバーで、保証が3年以上の商品」を EAV で書くとこうなる
SELECT a1.ProductId
FROM   dbo.DemoProductAttr AS a1
JOIN   dbo.DemoProductAttr AS a2
       ON a2.ProductId = a1.ProductId AND a2.AttrName = N'保証年'
WHERE  a1.AttrName = N'色' AND a1.AttrValue = N'シルバー'
  AND  TRY_CAST(a2.AttrValue AS INT) >= 3;     -- ★ 非SARGable、しかも変換失敗のリスク
```

**代わりにどうするか**:

1. **属性が分かっているなら、素直に列にする**。「将来増えるかも」は列追加で対応できます。
   `ALTER TABLE ADD` は(NULL 許容または既定値付きなら)**メタデータ操作だけで一瞬** で終わります。
2. **エンティティごとに種類が違うなら、サブタイプごとにテーブルを分ける**
   (`ProductsElectronics` / `ProductsFurniture` など)。
3. **本当に動的で、検索対象が限られるなら JSON 列**(22章)+ 検索する項目だけ
   **計算列にしてインデックス**(5-5 節)。型検証は `CHECK (ISJSON(...) = 1)` で最低限担保する。
4. **列が多くほとんど NULL なら スパース列** (`SPARSE`) という手もあります(NULL の格納コストがゼロになる)。

> ⚠️ EAV は「絶対禁止」ではありません。**ユーザーが実行時に項目定義を作れる製品**
> (アンケートツール、CRM のカスタム項目)では正当な選択です。
> ただし **そのコストを承知のうえで選ぶ** こと。「楽そうだから」で選んではいけません。

### 10-2. カンマ区切りで複数値を1列に詰める

2-3 節で見たとおりです。**代わりに交差テーブル**。
「一時的にしか使わない」なら `STRING_SPLIT`(**2016+**)で分解できますが、
**永続データとして持ってはいけません**。

### 10-3. 汎用的すぎるテーブル(One True Lookup Table)

```sql
-- ✗ すべてのコードマスタを1つに詰め込む
-- dbo.CodeMaster (CodeType NVARCHAR(30), Code NVARCHAR(20), Name NVARCHAR(100))
--   CodeType = N'部門' / N'カテゴリ' / N'地域' / N'ステータス' ...
```

- **外部キーが張れません**。`Orders.StatusCode` が「ステータス」の値であることを DB は保証できない。
  部門コードを入れても止められません。
- 型が全部 `NVARCHAR` に寄せられる。数値の区分も文字列になる。
- **すべてのクエリに `WHERE CodeType = N'...'` が付く**。それを忘れた瞬間にバグ。
- 統計情報が種類ごとに分かれない(EAV と同じ問題)。

**代わりにどうするか**: **種類ごとにテーブルを作る**。
`dbo.Categories`、`dbo.Departments` のように。テーブルが10個増えても構いません。
**それぞれに外部キーが張れる価値のほうが、はるかに大きい**。

### 10-4. 意味の異なる値を1列に共存させる

```
✗ Note 列に「未出荷」「返品済」「特記事項の自由文」が混在している
✗ Status 列に 数値コードと N'保留' のような文字列が混在している
✗ CustomerId = -1 が「未指定」を意味する(マジックナンバー)
✗ OrderDate = '1900-01-01' が「未定」を意味する
```

- **`WHERE` の条件が書けなくなる**。`WHERE Note = N'返品済'` は自由文が入った瞬間に破綻。
- マジックナンバーは **集計を壊します**。`AVG(Amount)` に `-1` が混ざる、
  `MIN(OrderDate)` が 1900年になる、など。
- しかも **その意味はどこにも書かれていない**。半年後の自分が必ず踏みます。

**代わりにどうするか**:

- 状態は **専用の列** に切り出し、`CHECK` か参照テーブル + `FOREIGN KEY` で値域を固定する。
- 「未指定・未定」は **`NULL` で表す**。これが `NULL` の正しい使い方です。
  サンプルDB の `Orders.ShipDate IS NULL`(未出荷)、`Employees.DepartmentId IS NULL`(未配属)が良い例。
- 自由文は自由文の列に。**構造化された情報と混ぜない**。

### 10-5. NULL の多用

`NULL` 自体は悪ではありません(上記のとおり「未知・非適用」を表す正しい手段です)。
問題は **「1つのテーブルに複数の実体を詰め込んだ結果、列の大半が NULL になっている」** 状態です。

```
✗ dbo.Party (PartyId, 個人_姓, 個人_名, 個人_生年月日,
             法人_商号, 法人_設立日, 法人_資本金, ...)
   → 個人の行では法人系の列が全部 NULL、法人の行では個人系が全部 NULL
```

何が壊れるか:

- **`NOT NULL` を書けない**。本当は個人には姓が必須なのに、制約で表現できない。
- 集計・結合のたびに `ISNULL` / `COALESCE` が必要になり、**非 SARGable なクエリが増える**(18章 4-3)。
- 3値論理の罠(`NOT IN` に NULL が混ざると1行も返らない)を全クエリで踏むリスク。
- 行が無駄に太る(固定長列は NULL でも領域を消費します)。

**代わりにどうするか**: **サブタイプに分割**します。

```
dbo.Party        (PartyId PK, PartyType, 共通の列...)
dbo.PartyPerson  (PartyId PK/FK, 姓, 名, 生年月日)     ← すべて NOT NULL にできる
dbo.PartyCompany (PartyId PK/FK, 商号, 設立日, 資本金) ← すべて NOT NULL にできる
```

こうすると **「個人なら姓は必須」というルールを DB が保証** できます。

> ⚠️ 逆に、**NULL を恐れて空文字や 0 を入れるのはもっと悪い**。
> 「値が無い」と「値が空文字である」は違う事実です。
> `AVG` は NULL を無視しますが `0` は平均に含めます。**意味を偽装しないこと**。

---

## 11. OLTP と分析系 — 設計思想はまったく違う

ここまでの正規化の話は、主に **OLTP(オンライン取引処理)** を前提にしていました。
**分析系(DWH / BI)は、意図的に違う設計** をします。

| | OLTP | 分析系(DWH) |
|---|---|---|
| 代表的な操作 | 1〜数行の挿入・更新・参照 | **数百万〜数億行の集計** |
| 最適な正規化度 | **3NF まで正規化** | **意図的に非正規化**(スタースキーマ) |
| 結合の数 | 多くてよい(1行なら安い) | **少ないほどよい**(全行に効く) |
| 更新 | 頻繁 | **ほぼ追記のみ**。過去は変わらない |
| 冗長列 | 避ける | **積極的に持つ**(集計の高速化) |
| インデックス | 行ストア B木 + カバリング(18章) | **列ストア**(30章) |
| 分割 | 通常不要 | **パーティション**(31章) |

### 11-1. スタースキーマ

```
        DimCustomer          DimProduct
             \                   /
              \                 /
   DimDate ──── ★ SalesFact ★ ──── DimEmployee
              /                 \
             /                   \
        DimRegion            DimChannel
```

- **ファクト表 (fact table)**: 出来事(売上・在庫移動・アクセスログ)を1行ずつ記録する。
  - **狭い**。列は「ディメンションへの外部キー」と「メジャー(数値)」だけ。
  - **巨大**。数千万〜数十億行。
  - **追記のみ**。過去行は基本的に更新しない。
- **ディメンション表 (dimension table)**: 「誰が・何を・いつ・どこで」を説明する属性。
  - **幅広い**。テキスト属性が多い。
  - **小さい**。数千〜数百万行。
  - **意図的に非正規化する**。商品 → カテゴリ → 大分類 を1つの `DimProduct` に平坦化する。
    正規化して階層をテーブルに分けた形は **スノーフレークスキーマ** と呼ばれますが、
    **結合が増えるぶんスターより遅くなる**ことが多く、通常はスターを選びます。
    ディメンションは小さいので冗長のコストが低いのです。

### 11-2. `dbo.SalesFact` はファクト表の形をしている

`sample-db/04_analytics_data.sql` を読み直してみましょう。

| 列 | 役割 |
|---|---|
| `SaleId BIGINT` | **代理キー**。狭くはないが、増加・一意・不変。クラスター化キーに適する |
| `SaleDate DATE` | **日付ディメンションへのキー**(3バイト。`DATETIME` を選ばなかったのが正解) |
| `CustomerId` / `ProductId` / `EmployeeId` / `RegionId` | **ディメンションへの外部キー(すべて `INT`)** |
| `Quantity` / `UnitPrice` / `Discount` | **メジャー** |
| `Amount` | **派生値の非正規化**(`Quantity * UnitPrice * (1 - Discount)`)。集計を速くするため |

さらに **物理設計上の意図** が2つ埋め込まれています。

1. **`SaleDate` が `SaleId` にほぼ比例した順に格納されている**。
   これにより列ストアの **セグメント除外(rowgroup elimination)** が効きます(30章)。
   ランダムな順に入れていたら、どのセグメントにも全期間のデータが混ざり、除外が一切効きません。
   **「どの順で格納するか」は列ストアでは設計そのもの** です。
2. **`CustomerId` は 1〜1000 の合成値で、`dbo.Customers` とは無関係**。
   だから結合してはいけない、と明記されています。
   実務のスタースキーマなら、ここに `DimCustomer(CustomerId, 顧客名, 地域, 業種, ...)` を用意します。

### 11-3. ディメンションと履歴 — SCD

「顧客の担当営業が2023年に変わった」とき、過去の売上はどちらの担当で集計すべきか。

- **Type 1(上書き)**: 最新の値だけ持つ。過去の集計結果が **遡って変わる**。
- **Type 2(履歴行を追加)**: `有効開始日 / 有効終了日` を持ち、**時点ごとに別の行**にする。
  ファクトは「その時点のディメンション行の代理キー」を参照する。
  → 過去の集計は過去のまま。**これが分析系の標準**です。

Type 2 の実装は [34 テンポラルテーブルと履歴設計](34_temporal_tables.md) の
システムバージョン管理テーブルと考え方が重なります。
`FOR SYSTEM_TIME AS OF` で「その時点のディメンション」を取り出せるのは強力です。

### 11-4. 日付ディメンションを持つ理由

分析系では `DimDate` テーブル(1日1行)を作るのが定石です。

- 会計年度、四半期、営業日フラグ、祝日、週番号など **`DATEPART` では出せない属性** を持てる。
- **`WHERE 年度 = 2023` が等値条件になり SARGable**(`YEAR(SaleDate) = 2023` を書かずに済む)。
- 「売上が0の日」も行として存在するので、**欠測日が空欄で出る**([09 集合演算](09_set_operations.md) の
  マスタとの外部結合パターン)。

> ⚠️ **同じデータベースで OLTP と分析を同居させると、両方が中途半端になります**。
> 更新のためのインデックスと集計のためのインデックスは要求が正反対だからです。
> 規模が大きくなったら、**分析は別DB・別サーバーに切り出す**(または
> [30 列ストア](30_columnstore.md) の非クラスター化列ストアで分離する)ことを検討してください。

---

## 12. 後片付け(必ず実行すること)

この章で作った実験用オブジェクトをすべて削除します。

```sql
-- ビューを先に消す(SCHEMABINDING が dbo.OrderDetails を固定しているため)
DROP VIEW IF EXISTS dbo.vw_DemoProductSales;
GO

DROP TABLE IF EXISTS dbo.DemoOrders;
DROP TABLE IF EXISTS dbo.DemoOrderLine;
DROP TABLE IF EXISTS dbo.DemoOrderHead;      -- 子(FK を持つ側)が先
DROP TABLE IF EXISTS dbo.DemoCustomer;
DROP TABLE IF EXISTS dbo.DemoSalesFlat;
DROP TABLE IF EXISTS dbo.DemoAssignment;
DROP TABLE IF EXISTS dbo.DemoJsonOrders;
DROP TABLE IF EXISTS dbo.DemoRowWide;
DROP TABLE IF EXISTS dbo.DemoRowNarrow;
DROP TABLE IF EXISTS dbo.DemoTypeMismatch;
DROP TABLE IF EXISTS dbo.DemoKeyGuid;
DROP TABLE IF EXISTS dbo.DemoKeySeqGuid;
DROP TABLE IF EXISTS dbo.DemoKeyInt;
DROP TABLE IF EXISTS dbo.DemoProductAttr;
GO

DROP SEQUENCE IF EXISTS dbo.DemoOrderNumberSeq;
GO

-- 確認: Demo で始まるオブジェクトが残っていないこと(0 行になれば OK)
SELECT SCHEMA_NAME(schema_id) AS スキーマ, name AS オブジェクト名, type_desc AS 種別
FROM   sys.objects
WHERE  name LIKE N'Demo%' OR name LIKE N'vw_Demo%'
ORDER  BY name;

-- 確認: 既存データが元どおりであること(20 行 / 42 行)
SELECT (SELECT COUNT(*) FROM dbo.Orders)       AS 注文件数,
       (SELECT COUNT(*) FROM dbo.OrderDetails) AS 明細件数;
```

- `DROP TABLE IF EXISTS` / `DROP VIEW IF EXISTS` / `DROP SEQUENCE IF EXISTS` は **2016+**。
- **外部キーがある場合は子テーブルから削除** します(`DemoOrderHead` → `DemoCustomer`)。
- `SCHEMABINDING` されたビューが残っていると `dbo.OrderDetails` の変更ができなくなるので、
  **ビューの削除は忘れないこと**。

---

## よくあるつまずき

- **「同じ値が2箇所にある = 冗長」と決めつける** → 判定は値ではなく意味(関数従属)。
  `OrderDetails.UnitPrice` は正規化違反ではない(3 節)。
- **正規化しすぎて結合だらけになる** → 3NF まで行けば十分。それ以上は BCNF 違反が実在する場合だけ。
  そして分析系は **意図的に非正規化する**(11 節)。
- **計測せずに非正規化する** → 非正規化は整合性リスクを買う取引。**先に実行プランで確認**する(4-1)。
- **非正規化した値をトリガーで維持したが、`MERGE` や一括ロードでズレた** → 検証クエリを定期実行する。
- **計算列にインデックスが張れない** → 式が非決定的か不正確。`COLUMNPROPERTY` で
  `IsDeterministic` / `IsPrecise` / `IsIndexable` を確認し、必要なら `PERSISTED`(5-3)。
- **インデックス付きビューを作ったのに使われない** → Standard エディションでは自動マッチングしない。
  `WITH (NOEXPAND)` を明示する(6-2)。SET オプションのずれも原因になる。
- **「念のため `BIGINT` / `NVARCHAR(MAX)` / `DATETIME2`」** → 行が太り、
  全クエリの IO が一律に増える。**必要十分な型を選ぶ**(7 節)。
- **金額に `FLOAT`** → 合計が合わない、等値比較が当たらない。必ず `DECIMAL`(7-4)。
- **`VARCHAR` 列に `N'...'` で比較して遅い** → 暗黙の型変換で列側が変換され Scan になる。
  プランの `CONVERT_IMPLICIT` を確認(7-5)。
- **GUID をクラスター化キーにして断片化に悩む** → `REBUILD` してもすぐ戻る。
  原因はキー設計。`NEWSEQUENTIALID()` か「PK 非クラスター化 + 連番クラスター化」へ(8-3)。
- **制約は付いているのに最適化に使われない** → `is_not_trusted = 1` を疑う。
  `WITH CHECK CHECK CONSTRAINT` で戻す(9-4)。
- **一括ロード前の `NOCHECK CONSTRAINT ALL` を戻し忘れる** → 定期点検クエリを回す(9-4)。
- **EAV / カンマ区切り / 汎用コードマスタを「柔軟性」と呼んでしまう** → 柔軟なのは書くときだけ。
  読むとき・守るときのコストを見積もる(10 節)。

## この章のまとめ

- **設計は「取り返しがつかないチューニング」**。クエリは後から直せるが、
  データ型・キー・正規化度は直すのに全表再構築とアプリ改修が要る。
- **正規化は暗記ではなく「何が壊れるか」で理解する**。
  更新時異常・挿入時異常・削除時異常を起こせなくするのが目的。
  1NF(1マス1値)/ 2NF(部分関数従属を排除)/ 3NF(推移的関数従属を排除)/
  BCNF(候補キーが重なる場合)。**実務は 3NF が到達点**。
- **`OrderDetails.UnitPrice` は冗長ではない**。「注文時点の単価」という別の事実。
  判定基準は **「元が変わったとき、この列も変わるべきか」**。
- **非正規化は計測してから**。維持手段は
  **計算列(同一行)→ インデックス付きビュー(集計)→ バッチ → トリガー** の順に検討する。
- **計算列**は `IsDeterministic` / `IsPrecise` / `IsIndexable` を `COLUMNPROPERTY` で確認。
  不正確なら `PERSISTED`。**式で書いたクエリにも自動でマッチ**するので SARGable 化の武器になる。
  JSON 値の索引化にも使える。
- **インデックス付きビュー**は `SCHEMABINDING` + `COUNT_BIG(*)` + `UNIQUE CLUSTERED`。
  自動マッチングは **Enterprise のみ**、Standard は **`NOEXPAND`**。代償は更新コストとスキーマ固定。
- **データ型は IO を決める**。**行サイズ → 1ページあたり行数 → 論理読み取り数** という直結の因果。
  `INT` を既定に、`DECIMAL` は精度9と10の間に崖、`DATE` は3バイト、`DATETIME2` は精度を明示。
  **金額に `FLOAT` は禁止**、`TEXT`/`NTEXT`/`IMAGE` は非推奨、`NVARCHAR(MAX)` は最後の手段。
  **暗黙の型変換は列側を変換してインデックスを殺す**。
- **キーは狭い・一意・不変・増加**。クラスター化キーは全非クラスタ化インデックスに複製される。
  **GUID をクラスター化キーにするとページ分割で断片化する** → `NEWSEQUENTIALID()` か
  PK 非クラスター化 + 連番クラスター化。`SEQUENCE` は事前採番・複数表共有が要るときに。
- **制約はオプティマイザへの前提知識**。信頼された `FOREIGN KEY` は **結合を除去** し、
  `CHECK` は **矛盾する述語を検出してテーブルアクセスを消す**。
  **`WITH NOCHECK` で付けた制約は `is_not_trusted = 1` になり、最適化に使われない**。
  `WITH CHECK CHECK CONSTRAINT` で戻す。
- **アンチパターン**(EAV / カンマ区切り / 汎用コードマスタ / 意味の混在 / NULL だらけ)は
  すべて「**型と制約による保証を捨てている**」点が共通。代替は
  素直な列・交差テーブル・種類別テーブル・サブタイプ分割・(本当に動的なら)JSON + 計算列。
- **OLTP と分析系は設計思想が正反対**。分析系はスタースキーマ(ファクト+ディメンション)で
  **意図的に非正規化**し、列ストアとパーティションを前提にする。
  `dbo.SalesFact` はその形をしており、格納順序まで設計に含まれている。

➡ 演習: [exercises/35_data_modeling.md](../exercises/35_data_modeling.md)
