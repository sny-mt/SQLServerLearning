# 18 インデックスと実行プラン

> **このトピックのゴール**: **同じ結果を返すクエリでも、書き方とインデックスの有無で
> コストが桁違いに変わる** ことを、実行プランと論理読み取り回数で「数字として」確認できるようになる。
> 特に **SARGability**(インデックスが効く条件の書き方)と **Key Lookup / カバリングインデックス** を体で覚える。
>
> **前提**: [17 ユーザー定義型とテーブル値パラメータ (TVP)](17_user_defined_types.md) までを済ませていること。
> **さらに、この章は `sample-db/03_bulk_data.sql` を実行して `dbo.OrdersBig`(100万行)を
> 作成済みであることが前提** です。まだなら先に実行してください(10〜60秒程度かかります)。

すべての例は先頭で `USE SalesLearning;` を実行済みとします。

この章だけは、これまでの 20 行の `dbo.Orders` ではなく **100万行の `dbo.OrdersBig`** を使います。
性能の話は、**行数が十分に多くないと差が見えない** からです。

```sql
-- 準備確認: 100万行あることを確かめる
SELECT COUNT(*) AS 行数,
       MIN(OrderDate) AS 最古,
       MAX(OrderDate) AS 最新
FROM   dbo.OrdersBig;
```

`dbo.OrdersBig` の構成(再掲):

| 列 | 型 | 内容 |
|---|---|---|
| `OrderId` | INT | **クラスタ化主キー**。1〜1,000,000 の連番 |
| `CustomerId` | INT | 1〜12 |
| `EmployeeId` | INT | 1〜13 |
| `OrderDate` | DATE | 2015-01-01〜2024-12-31 に分散(1日あたり約274行) |
| `ShipDate` | DATE NULL | 約5%が NULL |
| `Status` | NVARCHAR(10) | `N'完了'` 約95% / `N'保留'` 約5%(**偏りのある列**) |
| `Amount` | DECIMAL(12,0) | 金額 |

> ⚠️ **非クラスタ化インデックスはわざと1本も作っていません**。
> この章で自分の手で作り、作成前後のプランを比較するためです。

---

## 1. 実行プランの見かた

### 1-1. SSMS でプランを表示する

| 操作 | ショートカット | 内容 |
|---|---|---|
| **実際の実行プランを含める** | `Ctrl` + `M` | クエリを実行し、**本当に起きたこと**(実際の行数を含む)を表示 |
| **推定実行プランの表示** | `Ctrl` + `L` | クエリを **実行せずに** 見積もりだけ表示 |

- `Ctrl` + `M` は **トグル**です。押してから実行すると、結果グリッドの隣に「実行プラン」タブが出ます。
  もう一度押すと解除されます。
- `Ctrl` + `L` は実行しないので **重いクエリでも安全**。ただし「推定行数」しか見えません。
- **学習では原則 `Ctrl` + `M`**。推定と実際の乖離(9 節)は実際のプランでしか見えないからです。

SSMS を使えない環境では、テキストで出すこともできます。

```sql
SET SHOWPLAN_TEXT ON;    -- 以降のクエリは「実行されず」プランだけ返る
GO
SELECT COUNT(*) FROM dbo.OrdersBig WHERE OrderDate = '2023-06-01';
GO
SET SHOWPLAN_TEXT OFF;
GO
```

### 1-2. プランの読み方(3つのコツ)

1. **右から左、上から下に読む**。いちばん右のデータ取得(Scan / Seek)が出発点です。
2. **矢印の太さ = 流れる行数**。右のほうで太い矢印が出ていたら「余計な行を大量に読んでいる」サイン。
3. **各演算子のコスト %** は **オプティマイザの見積もり**であって実測値ではありません。
   100% と出ていても本当のボトルネックとは限らない。**必ず次の STATISTICS IO と併せて判断** します。

演算子にマウスを乗せると出るツールチップで、`実際の行数` / `推定行数`、`実行回数` を確認します。

### 1-3. STATISTICS IO / STATISTICS TIME(数字で測る)

プランの形だけでなく、**実際にどれだけページを読んだか** を数字で出します。

```sql
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

SELECT COUNT(*) FROM dbo.OrdersBig WHERE OrderDate = '2023-06-01';

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
```

「メッセージ」タブに次のような出力が出ます。

```
テーブル 'OrdersBig'。スキャン カウント 1、論理読み取り数 6018、物理読み取り数 0、先読み読み取り数 0、...

 SQL Server 実行時間:
   CPU 時間 = 172 ミリ秒、経過時間 = 61 ミリ秒。
```

読み方:

- **論理読み取り数(logical reads)= 8KB ページに何回アクセスしたか。この章で最重要の指標**。
  - キャッシュに乗っていても数えられるため、**実行するたびに安定した値** が出る。
  - CPU の空き具合・他人の負荷・ディスクの速さに **左右されない**。だから比較に使える。
- **物理読み取り数** … ディスクから実際に読んだページ数。2回目以降はキャッシュに乗って 0 になりがちで、
  **チューニングの前後比較には向きません**。
- **スキャン カウント** … そのテーブルへのアクセスが何回開始されたか(ループの内側なら増える)。
- **経過時間** は他の負荷でブレます。CPU 時間のほうがまだ安定しますが、
  **最終的な判断は論理読み取り数で** 行うのが定石です。

> ⚠️ 「速くなった気がする」は当てになりません。**チューニングの効果は
> 「論理読み取り数がいくつからいくつに減ったか」で語る**。これが本章の合言葉です。

> ⚠️ 本やネットには `DBCC DROPCLEANBUFFERS`(バッファキャッシュを空にする)で計測する例がありますが、
> **本番環境では絶対に実行しないこと**(サーバー全体のキャッシュを捨て、全ユーザーが遅くなります)。
> 論理読み取り数で比較すれば、そもそもキャッシュを空にする必要はありません。

---

## 2. インデックスの構造(B木)のイメージ

インデックスは **B木(バランス木)** という構造です。本の索引を思い浮かべてください。

```
                 [ルートページ]          ← 1ページ
              /        |        \
        [中間]      [中間]      [中間]   ← 数ページ
        /  |  \      /  \        /  \
   [葉][葉][葉] [葉][葉]  ...          ← 大量のページ(ここに実データ or キー)
```

- 上から順にたどると、**数回のページアクセスで目的の位置に到達** できます。
  100万行でも木の深さはせいぜい 3〜4 段。だから「1件取り出す」のに数ページしか読まない。
- **葉(リーフ)レベルは横方向に連結** されています。だから
  「2023-06-01 から 2023-06-30 まで」のような **範囲検索が速い**(先頭を見つけて右へ走るだけ)。

### 2-1. クラスタ化インデックス = テーブル本体そのもの

- **クラスタ化インデックスの葉には、行の全列データが入っています**。
  つまり「テーブル本体がクラスタ化キーの順に並べ替えられて格納されている」状態。
- したがって **1テーブルに1本だけ**。並び順は1つしか持てないからです。
- `dbo.OrdersBig` では `PK_OrdersBig PRIMARY KEY CLUSTERED (OrderId)` がそれにあたります。
  → データは **OrderId 順に物理的に並んでいる**。

```sql
-- OrderId で1件引くのは最速(クラスタ化キーでのシーク)
SET STATISTICS IO ON;
SELECT * FROM dbo.OrdersBig WHERE OrderId = 500000;   -- 論理読み取り数は 3〜4 程度
SET STATISTICS IO OFF;
```

100万行の中から1件を、**わずか3〜4ページ**で取ってこられます。これが B木の威力です。

### 2-2. 非クラスタ化インデックス = 別に持つ索引

- **葉にはインデックスのキー列と、行を特定するためのポインタだけ** が入ります。
  クラスタ化インデックスがあるテーブルでは、ポインタ = **クラスタ化キーの値**(ここでは `OrderId`)。
- 本体より **ずっと細い** ので、同じ行数でもページ数が少なくて済みます。
- 1テーブルに複数本作れます(ただしコストあり。11 節)。

> ⚠️ クラスタ化インデックスを持たないテーブルは **ヒープ (heap)** と呼ばれ、行の並び順は保証されません。
> ヒープの全件走査がプラン上の **Table Scan** です。`dbo.OrdersBig` はヒープではないので、
> 全件走査は **Clustered Index Scan** と表示されます(意味は同じ「全部読む」)。

---

## 3. Index Seek / Index Scan / Table Scan の違い

プラン上でいちばん最初に見るべきポイントです。

| 演算子 | 意味 | イメージ |
|---|---|---|
| **Clustered Index Seek** / **Index Seek** | B木をたどって **必要な範囲だけ** 取り出す | 索引で「か行」を引いて該当ページだけ開く |
| **Clustered Index Scan** / **Index Scan** | インデックスの **葉を端から端まで** 読む | 本を1ページ目から最後までめくる |
| **Table Scan** | **ヒープ**(クラスタ化インデックスなし)を全件読む | 同上。並び順すらない |

まず、インデックスが無い状態を体感します。

```sql
SET STATISTICS IO ON;

-- ① 特定日の注文件数(OrderDate に索引が無い)
SELECT COUNT(*) AS 件数
FROM   dbo.OrdersBig
WHERE  OrderDate = '2023-06-01';

SET STATISTICS IO OFF;
```

プラン: **Clustered Index Scan**。論理読み取り数は **6,000 前後**。
274 行を得るために、100万行ぶんのページを全部めくっています。

ここで `OrderDate` に非クラスタ化インデックスを作ります。

```sql
CREATE NONCLUSTERED INDEX IX_OrdersBig_OrderDate
    ON dbo.OrdersBig (OrderDate);
```

同じクエリを再実行すると:

プラン: **Index Seek (NonClustered)**。論理読み取り数は **3〜5 程度**。
**6,000 → 5。1000倍以上の差**です。これがインデックスの効果です。

> ⚠️ **Seek だから常に良い / Scan だから常に悪い、ではありません**。
> 100万行のうち 95万行を返すクエリなら、Scan のほうが正しい選択です。
> 見るべきは「**取り出したい行数に対して、読んだページ数が釣り合っているか**」。
> 274 行のために 6,000 ページ読むのが問題なのです。

> ⚠️ プランに **Index Scan** と出ていても、それが「細い非クラスタ化インデックスの走査」なら、
> テーブル本体の走査よりずっと安いことがあります。**演算子の名前だけでなく論理読み取り数を見る**こと。

---

## 4. SARGability(この章の最重要ポイント)

**SARG** = **S**earch **ARG**ument(検索引数)。
**SARGable な条件 = インデックスのシークに使える条件** のことです。

### 4-1. 大原則: 「**列を裸のまま左辺に置く**」

```
    ○ SARGable      :  列  比較演算子  式
    ✗ 非SARGable    :  関数(列)  や  列 * 2   を左辺に書く
```

インデックスは **`OrderDate` の値そのもの** を順番に並べたものです。
`YEAR(OrderDate)` の値は並べていないので、**全行に対して関数を計算してみるまで**
どの行が該当するか分からない → **走査するしかない** のです。

### 4-2. 実例: `YEAR()` を剥がす

```sql
SET STATISTICS IO ON;

-- ✗ 非SARGable: 列に関数を適用している → Index Scan
SELECT COUNT(*) AS 件数
FROM   dbo.OrdersBig
WHERE  YEAR(OrderDate) = 2023;

-- ○ SARGable: 範囲条件に書き換える → Index Seek
SELECT COUNT(*) AS 件数
FROM   dbo.OrdersBig
WHERE  OrderDate >= '2023-01-01'
  AND  OrderDate <  '2024-01-01';

SET STATISTICS IO OFF;
```

- 結果はどちらも **同じ約 100,000 件**。しかし論理読み取り数は
  **約 1,800(スキャン)→ 約 180(シーク)** と桁が変わります。
- 書き換えのイディオム: **`>= 期間の開始` かつ `< 翌期間の開始`**。
  `BETWEEN '2023-01-01' AND '2023-12-31'` は日付だけなら同じですが、
  列が `DATETIME` だと **12/31 23:00 の行が漏れる**ので、`>=` と `<` の形を習慣にしましょう。

> ⚠️ **`YEAR(OrderDate) = 2023` は「読みやすいが遅い」典型**です。
> [12 組み込み関数](12_builtin_functions.md) で覚えた `YEAR` / `MONTH` / `CONVERT` / `FORMAT` は
> **`SELECT` に書くぶんには自由ですが、`WHERE` と `JOIN` の左辺に書いた瞬間にインデックスが死にます**。
> 「関数は表示のため、条件は素の列で」と覚えてください。

### 4-3. その他の非SARGable パターンと書き換え

**(a) 列に算術演算をしている**

```sql
-- ✗ 列に * 2 をしている
SELECT COUNT(*) FROM dbo.OrdersBig WHERE Amount * 2 > 1000;

-- ○ 定数側に移す(数学的に同値な変形)
SELECT COUNT(*) FROM dbo.OrdersBig WHERE Amount > 500;
```

**(b) 先頭ワイルドカードの `LIKE`**

```sql
-- ✗ 前方が不定 → 木をたどれない(Scan)
SELECT COUNT(*) FROM dbo.OrdersBig WHERE Status LIKE N'%了';

-- ○ 前方一致なら Seek できる
SELECT COUNT(*) FROM dbo.OrdersBig WHERE Status LIKE N'完%';
```

- インデックスは「先頭から順に」並んでいるので、**先頭が分からなければ探しようがない**。
  電話帳で「名字の最後が『田』の人」を探すのと同じです。
- どうしても部分一致検索が要るなら、**フルテキストインデックス** など別の仕組みを検討します。

**(c) 型変換・書式化して比較している**

```sql
-- ✗ 列を文字列化してから比べている
SELECT COUNT(*) FROM dbo.OrdersBig
WHERE  CONVERT(VARCHAR(8), OrderDate, 112) = '20230601';

-- ○ 日付は日付のまま比べる
SELECT COUNT(*) FROM dbo.OrdersBig WHERE OrderDate = '2023-06-01';
```

**(d) `ISNULL` / `COALESCE` で包んでいる**

```sql
-- ✗ 列を ISNULL で包んでいる
SELECT COUNT(*) FROM dbo.OrdersBig
WHERE  ISNULL(ShipDate, '9999-12-31') > '2024-12-01';

-- ○ OR で分けて、それぞれ素の列で比較する
SELECT COUNT(*) FROM dbo.OrdersBig
WHERE  ShipDate IS NULL OR ShipDate > '2024-12-01';
```

**(e) 暗黙の型変換**

列の型と比較値の型が違うと、**列側が変換されてしまい** シークできなくなることがあります。

- `NVARCHAR` 列に `VARCHAR` リテラルを比較 → **リテラル側**が昇格されるので Seek は保てる。
- 逆に `VARCHAR` 列に `NVARCHAR` リテラルを比較 → **列側**が昇格され、Seek できないことがある。
- プランの警告アイコンに `CONVERT_IMPLICIT` と出ていたら、この罠を疑ってください。

日本語を扱う本プロジェクトでは、いずれにせよ **`N'完了'` のように必ず `N` を付ける**のが正解です。

> ⚠️ `WHERE 列 <> 値`、`WHERE NOT IN (...)`、`WHERE 列 IS NOT NULL` のような
> **「大半の行が該当する」条件**は、SARGable であってもシークが選ばれません
> (そもそも全部読むほうが速いので、それで正しい)。

---

## 5. Key Lookup とカバリングインデックス

### 5-1. Key Lookup とは

非クラスタ化インデックスの葉には **キー列とクラスタ化キーしか入っていません**(2-2 節)。
そのため `SELECT` にそれ以外の列があると、SQL Server は
**該当行ごとに本体のクラスタ化インデックスを引き直し** に行きます。これが **Key Lookup** です。

```sql
SET STATISTICS IO ON;

-- Amount はインデックスに含まれていない
SELECT OrderId, OrderDate, Amount
FROM   dbo.OrdersBig
WHERE  OrderDate = '2023-06-01';

SET STATISTICS IO OFF;
```

プランはこうなります(右から左に):

```
  Index Seek (IX_OrdersBig_OrderDate)  ─┐
                                        ├─ Nested Loops ─→ SELECT
  Key Lookup (PK_OrdersBig)            ─┘
```

- 論理読み取り数は **900 前後**。274 行ぶんの Key Lookup が、1件あたり 3〜4 ページを消費しています。
- Key Lookup は **1行ずつのランダムアクセス**なので、**該当行が増えるほど急激に高くつく**。

### 5-2. INCLUDE 列でカバリングインデックスにする

**カバリングインデックス** = そのクエリが必要とする列を **すべて含んでいる**インデックス。
本体を引きに行く必要がなくなり、**Key Lookup が消えます**。

`INCLUDE` は「**キーとしては使わないが、葉ページに一緒に置いておく列**」を指定する構文です。

```sql
-- 既存のインデックスを作り直して Amount を INCLUDE する
DROP INDEX IX_OrdersBig_OrderDate ON dbo.OrdersBig;

CREATE NONCLUSTERED INDEX IX_OrdersBig_OrderDate
    ON dbo.OrdersBig (OrderDate)
    INCLUDE (Amount);
```

もう一度、まったく同じクエリを実行してみてください。

- プランから **Key Lookup と Nested Loops が消え、Index Seek 一本**になります。
- 論理読み取り数は **900 前後 → 5 前後**。

これが本章のハイライトです。**クエリを1文字も変えずに、インデックスの設計だけで
論理読み取りが 200 分の 1 になりました**。

### 5-3. キー列と INCLUDE 列の使い分け

| | キー列 `(...)` | `INCLUDE (...)` |
|---|---|---|
| 用途 | **検索・並べ替え**に使う列 | **取り出すだけ**の列 |
| 位置 | B木の全レベル(中間ページにも載る) | **葉ページのみ** |
| 順序 | **意味がある**(6 節) | 意味がない |
| サイズ影響 | 大きい(中間ページも太る) | 比較的小さい |

- **`WHERE` / `JOIN` / `ORDER BY` に出る列はキー列へ**。
- **`SELECT` に出るだけの列は `INCLUDE` へ**。

> ⚠️ カバリングは万能ではありません。**`SELECT *` を素直にカバーしようとすると、
> テーブルをまるごと複製したのと同じ**になります。カバリングを狙うなら、
> まず **`SELECT` の列を必要最小限に削る**([01 SELECT の基礎](01_select_basics.md) の教えがここで効きます)。

### 5-4. ティッピングポイント(転換点)

Key Lookup が高くつくと、オプティマイザは **途中でスキャンに切り替えます**。

```sql
SET STATISTICS IO ON;

-- 1日ぶん(約274行)→ Seek + Key Lookup が選ばれる
SELECT OrderId, OrderDate, CustomerId, Status
FROM   dbo.OrdersBig
WHERE  OrderDate = '2023-06-01';

-- 1年ぶん(約100,000行)→ Key Lookup が高すぎるので Clustered Index Scan に切り替わる
SELECT OrderId, OrderDate, CustomerId, Status
FROM   dbo.OrdersBig
WHERE  OrderDate >= '2023-01-01' AND OrderDate < '2024-01-01';

SET STATISTICS IO OFF;
```

- 目安として、**テーブルのページ数の 1/4 〜 1/3 に相当する行数** を超えるあたりで転換します。
  100万行・約6,000ページなら **おおむね数千行**が境目です。
- 「インデックスを作ったのに Scan のまま」の多くはこれ。**インデックスが悪いのではなく、
  取り出す行数が多すぎる**のです。対処は `SELECT` の列を減らして **カバリングにする**こと。

---

## 6. 複合インデックスは列の順序がすべて

複数列のインデックスは、**電話帳(姓 → 名の順に並んでいる)** と同じです。

```sql
CREATE NONCLUSTERED INDEX IX_OrdersBig_Status_OrderDate
    ON dbo.OrdersBig (Status, OrderDate);
```

このインデックスは `(Status, OrderDate)` の順に並んでいます。したがって:

```sql
SET STATISTICS IO ON;

-- ① 先頭列 Status で絞れる → Seek できる(理想形)
SELECT COUNT(*) FROM dbo.OrdersBig
WHERE  Status = N'保留' AND OrderDate >= '2023-01-01' AND OrderDate < '2024-01-01';

-- ② 先頭列 Status で絞れる(2列目の条件なし)→ Seek できる
SELECT COUNT(*) FROM dbo.OrdersBig
WHERE  Status = N'保留';

-- ③ 先頭列 Status の条件がない → Seek できない(良くて Index Scan)
SELECT COUNT(*) FROM dbo.OrdersBig
WHERE  OrderDate >= '2023-01-01' AND OrderDate < '2024-01-01';

SET STATISTICS IO OFF;
```

- ③ が肝です。**電話帳で「名が『太郎』の人」を探せない**のと同じ理屈。
  姓が分からなければ、結局全部めくるしかありません。
- つまり `(A, B)` のインデックスは **`A` 単独の検索にも使えますが、`B` 単独には使えません**。

### 列順序の決め方(実践的な指針)

1. **等値条件(`=`)で使う列を先に**、範囲条件(`>`, `<`, `BETWEEN`, `LIKE 'x%'`)を後に。
   範囲条件より右の列は、シークの絞り込みには使えなくなります。
2. 等値条件が複数あるなら、**選択度が高い(＝該当行が少ない)列を先に**。
3. `ORDER BY` の順序と一致させられるなら、**Sort 演算子を丸ごと省略** できます(大きな効果)。

> ⚠️ `(Status, OrderDate)` と `(OrderDate, Status)` は **別物**です。
> 「同じ2列だからどちらでもいい」は誤りで、想定するクエリに合わせて決めます。

---

## 7. 統計情報と基数推定

SQL Server は「この条件なら何行くらい返るか」を **統計情報(ヒストグラム)** から見積もり、
その **推定行数(cardinality estimate)** をもとにプランを決めます。

```sql
-- インデックスに付随する統計のヒストグラムを見る
DBCC SHOW_STATISTICS ('dbo.OrdersBig', IX_OrdersBig_Status_OrderDate);
```

出力は3つの結果セットです。

- **ヘッダー** … `Rows`(統計作成時の行数)、`Rows Sampled`(サンプル数)、`Updated`(最終更新日時)。
- **密度ベクター** … 列の組み合わせごとの平均的な重複度。等値条件の見積もりに使われる。
- **ヒストグラム** … 最大 200 ステップで値の分布を持つ。`RANGE_HI_KEY`(区間の上限値)、
  `EQ_ROWS`(その値ちょうどの行数)、`RANGE_ROWS`(区間内の行数)。

### 7-1. 推定行数と実際の行数の乖離を見る

**実際の実行プラン(`Ctrl` + `M`)** で演算子にマウスを乗せ、
**`推定行数` と `実際の行数`** を見比べます。**桁が違っていたら要注意**です。

```sql
-- ローカル変数を使うと、オプティマイザは実行前に中身を知ることができない
DECLARE @d DATE = '2024-12-01';

SELECT COUNT(*) FROM dbo.OrdersBig WHERE OrderDate >= @d;
```

- 変数の値はコンパイル時には未知なので、**ヒストグラムを使えず「平均的な推定値」**
  (範囲条件なら全体の約 30%)が使われます。推定 300,000 行に対して実際は約 8,500 行、といった乖離が起きます。
- 乖離すると、**不適切な結合方式(Hash なのに Nested Loops)や、
  小さすぎるメモリ確保(tempdb への spill 警告)** につながります。
- 中間結果を [15 一時テーブルとテーブル変数](15_temp_tables.md) の **一時テーブル**に落とすと、
  そこに統計が作られるため推定が改善することがあります(テーブル変数は統計を持たないので逆効果になりがち)。

対処:

```sql
DECLARE @d DATE = '2024-12-01';

SELECT COUNT(*) FROM dbo.OrdersBig WHERE OrderDate >= @d
OPTION (RECOMPILE);          -- 実際の値を見てからコンパイルさせる
```

### 7-2. 統計が古いとき

```sql
-- 統計の状態(最終更新日・それ以降の変更行数)を確認
SELECT s.name AS 統計名,
       sp.last_updated AS 最終更新,
       sp.rows         AS 行数,
       sp.rows_sampled AS サンプル行数,
       sp.modification_counter AS 更新後の変更行数
FROM   sys.stats AS s
CROSS  APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
WHERE  s.object_id = OBJECT_ID('dbo.OrdersBig');

-- 手動で更新(FULLSCAN は全行を読むので正確だが重い)
UPDATE STATISTICS dbo.OrdersBig WITH FULLSCAN;
```

- 通常は自動更新に任せて構いません(**AUTO_UPDATE_STATISTICS** が既定で ON)。
- ただし大量 INSERT/DELETE の直後や、**プランが急に悪化したとき**は疑ってみる価値があります。

---

## 8. 偏りのあるデータと選択度 — `Status` 列

`Status` は `N'完了'` が約95%、`N'保留'` が約5% という **強く偏った列** です。
まず `Status` 単独のインデックスを作ります。

```sql
CREATE NONCLUSTERED INDEX IX_OrdersBig_Status
    ON dbo.OrdersBig (Status);
```

**同じ形のクエリなのに、リテラルの値だけでプランが変わる** ことを確認してください。

```sql
SET STATISTICS IO ON;

-- ① 保留(約 50,000 行 = 5%)→ Index Seek が選ばれる
SELECT COUNT(*) FROM dbo.OrdersBig WHERE Status = N'保留';

-- ② 完了(約 950,000 行 = 95%)→ 大半が該当するので Scan が選ばれる
SELECT COUNT(*) FROM dbo.OrdersBig WHERE Status = N'完了';

SET STATISTICS IO OFF;
```

### 選択度(selectivity)

- **選択度 = 該当行数 ÷ 全行数**。小さいほど「よく絞れる」= インデックス向き。
- `Status = N'保留'` は 5% → **選択度が高い(絞れる)** のでシークが有効。
- `Status = N'完了'` は 95% → **絞れていない**ので、シーク+ルックアップより全件走査が速い。
- **性別・都道府県・フラグ列のように値の種類が少ない列は、単体ではインデックス効果が薄い**
  のが原則です。ただし今回の `保留` のように「稀な値だけを頻繁に検索する」なら十分価値があります。

> ⚠️ **パラメーター スニッフィング**: ストアドプロシージャで `WHERE Status = @s` と書くと、
> **最初に実行されたときの引数**でプランが作られ、以後キャッシュされます。
> 初回が `N'保留'` なら Seek プランが、`N'完了'` なら Scan プランが固定され、
> **逆の値で呼ばれたときに極端に遅くなる**。これが「昨日まで速かったのに今日は遅い」の典型的な正体です。
> 対処は `OPTION (RECOMPILE)` や `OPTIMIZE FOR` など([16 ストアドプロシージャ](16_stored_procedures.md) 参照)。

### フィルター選択されたインデックス(参考)

稀な値だけを狙うなら、**その値だけを持つ小さなインデックス**を作る手もあります。

```sql
CREATE NONCLUSTERED INDEX IX_OrdersBig_Status_Pending
    ON dbo.OrdersBig (OrderDate)
    WHERE Status = N'保留';        -- フィルター選択されたインデックス
```

- 5% ぶんしか持たないので **小さく・更新も軽い**。
- ただしクエリの条件が **インデックスの `WHERE` を包含している** 必要があります。

---

## 9. インデックスのコスト — 貼りすぎない判断

インデックスは **タダではありません**。読み取りを速くする代わりに、次を支払います。

1. **更新が遅くなる**。`INSERT` / `UPDATE` / `DELETE` のたびに、
   **全部の非クラスタ化インデックスも書き換える**必要があります。10本貼れば書き込みは10箇所。
2. **ディスクとメモリを食う**。インデックスもバッファプールに載るので、
   **データ本体のキャッシュを追い出します**。
3. **メンテナンスが要る**。断片化すると効果が落ち、再構成・再構築が必要になります。

サイズを確認してみましょう。

```sql
SELECT i.name                          AS インデックス名,
       i.type_desc                     AS 種別,
       SUM(ps.used_page_count) * 8     AS 使用KB,
       SUM(ps.row_count)               AS 行数
FROM   sys.indexes AS i
JOIN   sys.dm_db_partition_stats AS ps
       ON  ps.object_id = i.object_id
       AND ps.index_id  = i.index_id
WHERE  i.object_id = OBJECT_ID('dbo.OrdersBig')
GROUP  BY i.name, i.type_desc
ORDER  BY 使用KB DESC;
```

### 使われていないインデックスを探す

```sql
SELECT i.name                       AS インデックス名,
       us.user_seeks                AS シーク回数,
       us.user_scans                AS スキャン回数,
       us.user_lookups              AS ルックアップ回数,
       us.user_updates              AS 更新回数        -- ← これだけ大きいなら「重荷」
FROM   sys.indexes AS i
LEFT   JOIN sys.dm_db_index_usage_stats AS us
       ON  us.object_id = i.object_id
       AND us.index_id  = i.index_id
       AND us.database_id = DB_ID()
WHERE  i.object_id = OBJECT_ID('dbo.OrdersBig');
```

- `user_seeks + user_scans + user_lookups` がほぼ 0 なのに `user_updates` が大きいインデックスは
  **削除候補**です(統計は SQL Server の再起動でリセットされる点に注意)。

### 実践的な指針

- **まず1本、狙いを定めて作る**。作ったら必ず前後の論理読み取り数を比較して効果を確認する。
- **似たインデックスは統合する**。`(OrderDate)` と `(OrderDate, Status)` があるなら、
  前者は後者に含まれるので不要なことが多い。
- SSMS のプランに出る **「不足しているインデックス」の緑の提案は鵜呑みにしない**。
  提案は「そのクエリ1本」だけを見た近視眼的なもので、`INCLUDE` に列を並べすぎる傾向があります。
  **ヒントとして読み、自分で列と順序を決める**こと。
- **書き換えで済むならインデックスを増やさない**。4 節の SARGable 化は **ノーコストの改善** です。

---

## 10. 後片付け

この章で作ったインデックスは、**必ず削除してから次に進んでください**。
`dbo.OrdersBig` を「非クラスタ化インデックスが1本もない」初期状態に戻します。

```sql
DROP INDEX IF EXISTS IX_OrdersBig_OrderDate        ON dbo.OrdersBig;
DROP INDEX IF EXISTS IX_OrdersBig_Status           ON dbo.OrdersBig;
DROP INDEX IF EXISTS IX_OrdersBig_Status_OrderDate ON dbo.OrdersBig;
DROP INDEX IF EXISTS IX_OrdersBig_Status_Pending   ON dbo.OrdersBig;

-- 残っていないことを確認(PK_OrdersBig だけになっていれば OK)
SELECT name, type_desc
FROM   sys.indexes
WHERE  object_id = OBJECT_ID('dbo.OrdersBig')
  AND  index_id > 0;
```

- `DROP INDEX IF EXISTS`(**2016+**)は、存在しなくてもエラーになりません。
- 主キーのクラスタ化インデックス `PK_OrdersBig` は消さないこと(制約なので `DROP INDEX` では消せません)。

> ⚠️ 途中でおかしくなったら、`sample-db/03_bulk_data.sql` を再実行すれば
> `dbo.OrdersBig` を丸ごと作り直せます(既存の小さいテーブルには影響しません)。

---

## よくあるつまずき

- **「速くなった気がする」で判断してしまう** → 経過時間はブレる。**論理読み取り数**で比較する。
- **インデックスを作ったのに Scan のまま** → ①条件が非SARGable(4 節)、
  ②取り出す行数が多すぎてティッピングポイントを超えた(5-4 節)、③先頭列で絞れていない(6 節)。
- **`YEAR(OrderDate) = 2023` が遅い** → 列に関数を適用している。`>=` / `<` の範囲条件に書き換える。
- **プランに Key Lookup が出て遅い** → `SELECT` の列を減らすか、その列を `INCLUDE` に足す(5 節)。
- **`SELECT *` のままカバリングしようとする** → テーブルの複製になる。まず列を絞る。
- **推定行数と実際の行数が桁違い** → 統計が古い、またはローカル変数/パラメーターで値が見えていない。
  `UPDATE STATISTICS` や `OPTION (RECOMPILE)` を検討(7 節)。
- **同じプロシージャが日によって遅い** → パラメーター スニッフィング(8 節)。
- **とりあえずインデックスを大量に貼る** → 更新が重くなりキャッシュを圧迫する。**使われているか計測**する(9 節)。
- **物理読み取り数が 0 だから速い、と誤解する** → 2回目以降はキャッシュ済みで当然 0 になる。

## この章のまとめ

- **`Ctrl`+`M`(実際のプラン)/ `Ctrl`+`L`(推定プラン)** と
  **`SET STATISTICS IO ON`** をセットで使う。**論理読み取り数が最重要指標**。
- インデックスは **B木**。**クラスタ化 = テーブル本体そのもの(1本だけ)**、
  **非クラスタ化 = キー列+クラスタ化キーだけを持つ細い索引**。
- **Seek(必要な範囲だけ)/ Scan(葉を全部)/ Table Scan(ヒープ全部)**。
  名前だけでなく「行数に対して読んだページ数が釣り合っているか」で判断する。
- **SARGability が最重要**。`WHERE` の左辺で **列を関数や演算で包まない**。
  `YEAR(列)=2023` → `列 >= '2023-01-01' AND 列 < '2024-01-01'`。
  先頭 `LIKE '%...'`、`列*2 > n`、`CONVERT(列)`、`ISNULL(列,…)` も同罪。
- **Key Lookup** は非クラスタ化インデックスから本体を引き直すコスト。
  **`INCLUDE` でカバリングインデックス**にすれば消える(論理読み取りが桁で減る)。
- **複合インデックスは列順序がすべて**。先頭列で絞れないと使えない。等値 → 範囲の順に並べる。
- **統計情報**が推定行数を決める。**推定と実際の乖離**はプランで確認し、
  `UPDATE STATISTICS` / `OPTION (RECOMPILE)` を検討する。
- **偏った列(`Status`)** では、リテラルの値ひとつでプランが変わる。**選択度**で考える。
  パラメーター スニッフィングにも注意。
- インデックスは **更新コストと容量を払って読み取りを買う**もの。**貼りすぎない**。
  **クエリの書き換えで済むならそれが最善**。

➡ 演習: [exercises/18_indexes_execution_plans.md](../exercises/18_indexes_execution_plans.md)
