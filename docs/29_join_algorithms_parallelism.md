# 29 結合アルゴリズムと並列処理

> **このトピックのゴール**: `INNER JOIN` という **たった1つの論理演算** が、
> **Nested Loops / Merge / Hash** という **3つの物理演算子** のどれで実行されるのかを、
> プランと論理読み取り数から読み解けるようになる。さらに、それらが要求する
> **メモリ許可 (memory grant)** と **tempdb へのスピル**、そして **並列実行 (parallelism)** の
> しくみと落とし穴を、DMV と実行プランで **計測して** 切り分けられるようになる。
>
> **前提**: [28 パラメータスニッフィング詳解](28_parameter_sniffing.md) までを済ませていること。
> また **`sample-db/03_bulk_data.sql` を実行して `dbo.OrdersBig`(100万行)を作成済み**であること。
> 演習開始時点で `dbo.OrdersBig` に **非クラスタ化インデックスが1本もない** 状態が正しいスタート地点です。

すべての例は先頭で `USE SalesLearning;` を実行済みとします。

[04 テーブル結合 (JOIN)](04_joins.md) では「**どんな結果を得たいか**」を学びました。
この章のテーマは「**その結果を、SQL Server が物理的にどうやって作っているか**」です。
[18 インデックスと実行プラン](18_indexes_execution_plans.md) で覚えた
「論理読み取り数で語る」作法をそのまま使います。

---

## 1. 論理結合と物理結合演算子は別物

`INNER JOIN` / `LEFT JOIN` / `FULL JOIN` は **論理的な結合の種類** です。
「**どの行が結果に残るか**」を決めるもので、**実行方法は何も決めていません**。

一方、実行プランに現れるのは **物理演算子** です。等値結合の場合、選択肢は次の3つです。

| 物理演算子 | プラン上の表示 | ひとことで言うと |
|---|---|---|
| **Nested Loops Join** | `Nested Loops` | 外側の1行ごとに内側を **引きに行く** |
| **Merge Join** | `Merge Join` | **ソート済みの2列** を上から突き合わせる |
| **Hash Join** | `Hash Match` | 小さい側で **ハッシュ表** を作り、大きい側を流す |

重要なのは次の点です。

- **論理結合と物理演算子は1対1ではありません**。同じ `INNER JOIN` が、
  データ量・インデックス・統計情報の状態によって **3通りのどれにでも** なります。
- **どれが偉いということはありません**。「小さい結果を1件引く」なら Nested Loops、
  「100万行を丸ごと突き合わせる」なら Hash が正解です。
  **状況に対して間違った演算子が選ばれたときだけが問題**なのです。
- 選ぶのは **オプティマイザ** で、その判断材料は **推定行数**
  ([27 統計情報とカーディナリティ推定](27_statistics_cardinality.md))です。
  つまり **結合方式の誤選択は、ほぼすべて推定の誤りが原因**です。

> ⚠️ `LEFT JOIN` だから遅い、`INNER JOIN` だから速い、という話ではありません。
> 遅さの原因は論理結合の種類ではなく、**選ばれた物理演算子と、その入力の行数**にあります。

### 1-1. まず「同じクエリが変わる」ところを見る

`WHERE` の選択度だけを変えて、同じ形の結合を2回実行してみてください。

```sql
SET STATISTICS IO ON;

-- ① 外側が 100 行しかない → Nested Loops が選ばれる
SELECT o.OrderId, o.OrderDate, c.CustomerName
FROM   dbo.OrdersBig AS o
INNER JOIN dbo.Customers AS c ON c.CustomerId = o.CustomerId
WHERE  o.OrderId BETWEEN 1 AND 100;

-- ② 絞り込みを外して 100万行にする → Hash Match に変わる
SELECT c.CustomerName, COUNT(*) AS 件数
FROM   dbo.OrdersBig AS o
INNER JOIN dbo.Customers AS c ON c.CustomerId = o.CustomerId
GROUP  BY c.CustomerName;

SET STATISTICS IO OFF;
```

- ① は `Clustered Index Seek (PK_OrdersBig)` → `Nested Loops` → `Customers` への
  `Clustered Index Seek` が 100 回。論理読み取り数は **数百程度**。
- ② は `Clustered Index Scan` → `Hash Match`。`OrdersBig` の論理読み取り数は **約 6,000**。

**クエリの文面ではなく、流れる行数が演算子を決めている**ことを確認してください。

---

## 2. 計測の準備

この章は「プランの形」と「数字」を必ずセットで見ます。次の3つを用意します。

```sql
-- ① 実際の実行プラン: SSMS で Ctrl + M を ON にする
-- ② 数字での計測
SET STATISTICS IO ON;
SET STATISTICS TIME ON;
```

`SET STATISTICS TIME` の出力は、この章では **18章より重要**になります。

```
 SQL Server 実行時間:
   CPU 時間 = 1250 ミリ秒、経過時間 = 320 ミリ秒。
```

- **CPU 時間 > 経過時間 なら、そのクエリは並列実行されています**。
  複数スレッドが同時に CPU を使ったぶん、CPU 時間の合計が実時間を超えるためです。
- 逆に **CPU 時間 ≒ 経過時間 なら直列(シリアル)実行**です。
- これは **プランを開かなくても並列かどうかが分かる**、いちばん手軽な判定法です。

> ⚠️ 論理読み取り数は相変わらず「安定した比較指標」ですが、
> **メモリ許可・スピル・並列の話は論理読み取り数だけでは見えません**。
> この章では **プランの警告アイコン** と **DMV** を必ず併用します。

---

## 3. Nested Loops Join(入れ子ループ結合)

### 3-1. しくみ

```
外側 (outer / build ではない) の各行について:
    その行の結合キーを使って、内側 (inner) を検索する
    見つかった行と組み合わせて出力する
```

擬似コードで書けば二重ループそのものです。

```
FOR EACH row_o IN 外側:
    FOR EACH row_i IN 内側 WHERE row_i.key = row_o.key:
        OUTPUT (row_o, row_i)
```

- **コストはおおよそ「外側の行数 × 内側を1回引くコスト」**。
  この式がすべてを説明します。
- プラン上、**内側の演算子の「実行回数 (Number of Executions)」= 外側の行数** になります。
  ツールチップでこれを確認するのが読み方のコツです。
- **ブロックしない**(全件揃うのを待たずに1行目から返せる)ため、
  `TOP` や `EXISTS` のような「最初の数行だけ欲しい」クエリと相性が抜群です。
- **等値以外の結合条件(`<`, `LIKE`, 不等号)でも使える唯一のアルゴリズム**です。
  Merge と Hash は **等値条件が最低1つ必要**なので、非等値結合は自動的に Nested Loops になります。

### 3-2. 最速になる条件

**外側が小さく、内側の結合キーにインデックスがあり、1回のシークで取れる行が少ない**。
この3つが揃ったときだけです。OLTP の「注文1件を顧客マスタと突き合わせる」がまさにこれです。

```sql
SET STATISTICS IO ON;

-- 外側 100 行 × 内側 (Customers/Employees の主キー) へのシーク
SELECT o.OrderId, o.OrderDate, c.CustomerName, e.LastName AS 担当
FROM   dbo.OrdersBig AS o
INNER JOIN dbo.Customers AS c ON c.CustomerId = o.CustomerId
INNER JOIN dbo.Employees AS e ON e.EmployeeId = o.EmployeeId
WHERE  o.OrderId BETWEEN 1 AND 100;

SET STATISTICS IO OFF;
```

`Customers`・`Employees` のスキャン カウントが 100 前後になっているはずです
(= 内側が 100 回実行された)。**ループの内側はスキャン カウントで数える**と覚えてください。

### 3-3. 内側にインデックスが無いと何が起きるか

内側にインデックスが無ければ、**外側の1行ごとに内側を丸ごと走査** します。
つまり「フルスキャン × 外側の行数」。これが Nested Loops の破綻パターンです。

わざと起こしてみます(`dbo.OrdersBig` の `EmployeeId` にはインデックスがありません)。

```sql
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

-- ○ 素直に任せた場合 → Hash Match。OrdersBig の論理読み取りは約 6,000
SELECT e.LastName, COUNT(*) AS 件数
FROM   dbo.Employees AS e
INNER JOIN dbo.OrdersBig AS o ON o.EmployeeId = e.EmployeeId
GROUP  BY e.LastName;

-- ✗ Nested Loops を強制する(絶対に本番でやらないこと。ここは学習用)
SELECT e.LastName, COUNT(*) AS 件数
FROM   dbo.Employees AS e
INNER JOIN dbo.OrdersBig AS o ON o.EmployeeId = e.EmployeeId
GROUP  BY e.LastName
OPTION (LOOP JOIN, FORCE ORDER, MAXDOP 1);

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
```

- 後者の `OrdersBig` の論理読み取り数は **約 78,000**(≒ 6,000 ページ × 13 人)。
  スキャン カウントも **13** になります。**13倍のコストを払っている**のが数字で見えます。
- 環境によって前後しますが、**桁が1つ増える**ことは確実に再現します。

> ⚠️ 実務で「ある日から急に特定のクエリだけ数十倍遅くなった」の典型が **これ**です。
> 統計が古くなって外側の推定行数が「1行」になり、
> 「1回だけ内側を引くなら安い」と判断されて Nested Loops が選ばれ、
> **実際には10万行流れてきて内側を10万回引いた**、というパターン。
> プランで **推定行数と実際の行数を比べる**([18 の 7-1](18_indexes_execution_plans.md))と一発で分かります。

### 3-4. インデックスがあれば常に速い、でもない

`EmployeeId` にインデックスを作ってから、もう一度 Nested Loops を強制してみてください。

```sql
CREATE NONCLUSTERED INDEX IX_OrdersBig_EmployeeId
    ON dbo.OrdersBig (EmployeeId);
GO

SET STATISTICS IO ON;

SELECT e.LastName, COUNT(*) AS 件数
FROM   dbo.Employees AS e
INNER JOIN dbo.OrdersBig AS o ON o.EmployeeId = e.EmployeeId
GROUP  BY e.LastName
OPTION (LOOP JOIN, FORCE ORDER, MAXDOP 1);

SET STATISTICS IO OFF;
```

シークにはなりますが、**1人あたり約 77,000 行**がヒットするので、結局 100万行を読むことに変わりはありません。
オプティマイザに任せれば、やはり Hash Match が選ばれます。

**Nested Loops の条件は「内側にインデックスがある」だけでは足りません。**

1. 外側の行数が **少ない**
2. 内側に **結合キーのインデックスがある**
3. **1回のシークで返る行が少ない**(= 結合キーの選択度が高い)

3つ揃ってはじめて最速です。

### 3-5. 補足: プランで見かける関連表示

- **Nested Loops (Left Outer Join)** … `LEFT JOIN` を Nested Loops で実行したときの表示。
  論理結合の種類は演算子名の括弧内に出ます。
- **Key Lookup の相棒** … 18章で見た `Index Seek` + `Key Lookup` の組も、
  必ず `Nested Loops` でつながれています。あれも入れ子ループ結合の一種です。
- **Optimized Nested Loops(バッチソート)** … 内側のランダムアクセスを減らすため、
  オプティマイザが暗黙に外側をソートすることがあります。
  この **暗黙のソートもメモリ許可を要求します**(7節につながります)。

---

## 4. Merge Join(マージ結合)

### 4-1. しくみ

**両方の入力が結合キーでソート済み**であることが前提です。
2つのソート済みリストを、両側のカーソルを進めながら突き合わせます。

```
両側の先頭から:
    左のキー = 右のキー → 出力して両方を進める
    左のキー < 右のキー → 左を進める
    左のキー > 右のキー → 右を進める
```

- **各入力を1回ずつ読むだけ**で終わります。これ以上ないほど効率的です。
- **等値条件が最低1つ必要**です(不等号だけの結合には使えません)。
- 出力も **結合キー順にソートされた状態** で出てくるので、
  後続の `ORDER BY` / `GROUP BY` / `MERGE` 系の演算で `Sort` を省略できることがあります。

### 4-2. ソート済みなら最強、ソートが要るなら一転して高コスト

「ソート済み」を用意する方法は2つです。

1. **インデックス順に読む**(コストゼロ。これが理想)
2. **`Sort` 演算子で並べ替える**(**全行をメモリに載せる**。高コスト・スピルの危険)

`dbo.Customers` は `CustomerId` の主キー(=クラスタ化)順に並んでいます。
`dbo.OrdersBig` 側にも `CustomerId` 順のインデックスを作れば、**両側がソート済み**になります。

```sql
CREATE NONCLUSTERED INDEX IX_OrdersBig_CustomerId
    ON dbo.OrdersBig (CustomerId);
GO

SET STATISTICS IO ON;
SET STATISTICS TIME ON;

-- ① 両側がインデックス順に読める → Sort なしの Merge Join
SELECT c.CustomerName, COUNT(*) AS 件数
FROM   dbo.OrdersBig AS o
INNER JOIN dbo.Customers AS c ON c.CustomerId = o.CustomerId
GROUP  BY c.CustomerName
OPTION (MERGE JOIN, MAXDOP 1);

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
```

プランに **`Sort` が出ていないこと**を確認してください。
`OrdersBig` 側は細い非クラスタ化インデックスを順に読むだけなので、
クラスタ化インデックスの全走査(約 6,000)より **論理読み取り数が減ります**(約 1,700〜2,000 が目安)。

次に、インデックスが使えない列で Merge Join を強制してみます。

```sql
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

-- ② EmployeeId 順のインデックスが無い状態で Merge を強制 → 100万行の Sort が入る
SELECT e.LastName, COUNT(*) AS 件数
FROM   dbo.Employees AS e
INNER JOIN dbo.OrdersBig AS o ON o.EmployeeId = e.EmployeeId
GROUP  BY e.LastName
OPTION (MERGE JOIN, MAXDOP 1);

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
```

- プランの右のほうに **`Sort`** が現れ、そこにコストの大半が集中します。
- この `Sort` は **100万行ぶんのメモリを予約** します。足りなければ **tempdb にスピル**します(7節)。
- 「Merge Join は効率的」は **入力がすでに並んでいる場合の話**であって、
  **並べるところから始めるなら Hash Join のほうが安い**のが普通です。

> ⚠️ 3-4 節で作った `IX_OrdersBig_EmployeeId` が残っていると ② でも Sort が消える可能性があります。
> ここでは「ソートが必要な Merge Join がどうなるか」を見たいので、
> このインデックスを一度削除してから試すか、`OPTION (MERGE JOIN, MAXDOP 1, INDEX(...))` ではなく
> **11節の後片付けを済ませた状態**で改めて確認してください。

### 4-3. 一対多と多対多

Merge Join には2つのモードがあります。プランの演算子プロパティで確認できます。

| プロパティ | 意味 | コスト |
|---|---|---|
| `Many to Many = False`(一対多) | **片側の結合キーが一意** であることをオプティマイザが保証できる | 安い。追加リソース不要 |
| `Many to Many = True`(多対多) | **両側に重複キーがありうる** | **tempdb のワークテーブル**を使って巻き戻す |

- 一対多になるのは、片側が **主キー・一意インデックス・`GROUP BY` の結果** など、
  「このキーは重複しない」と **メタデータから証明できる**場合だけです。
- 多対多では、右側で同じキーが続く区間を **何度も読み直す** 必要があるため、
  内部的に tempdb のワークテーブルへ退避します。`STATISTICS IO` の出力に
  **`ワークテーブル`(Worktable)** の行が現れたら、これを疑ってください。

```sql
SET STATISTICS IO ON;

-- 両側とも CustomerId が重複する → 多対多の Merge Join になりうる
-- (行数が爆発するので COUNT だけ取り、TOP で入力を絞っている)
SELECT COUNT_BIG(*) AS 組合せ数
FROM   (SELECT TOP (5000) OrderId, CustomerId FROM dbo.OrdersBig ORDER BY CustomerId) AS a
INNER JOIN (SELECT TOP (5000) OrderId, CustomerId FROM dbo.OrdersBig ORDER BY CustomerId) AS b
       ON a.CustomerId = b.CustomerId
OPTION (MERGE JOIN, MAXDOP 1);

SET STATISTICS IO OFF;
```

> ⚠️ `CustomerId` は 12 種類しかないため、**重複キーの結合は組み合わせ爆発**を起こします。
> 上の例で `TOP (5000)` を外すと 100万 × 100万 に近い規模になり、いつまでも終わりません。
> **必ず `TOP` を付けたまま実行してください。**

---

## 5. Hash Join(ハッシュ結合)

### 5-1. しくみ

2フェーズで動きます。

```
【build フェーズ】小さいほうの入力を全部読み、結合キーのハッシュ表をメモリ上に作る
【probe  フェーズ】大きいほうの入力を1行ずつ流し、ハッシュ表を引いて一致を探す
```

- **ソートも不要、インデックスも不要**。大量データ同士の結合ではこれが定石です。
- **等値条件が最低1つ必要**です(ハッシュ値が一致するかどうかで探すため)。
- build フェーズは **ブロッキング**です。build 側を **全部読み終わるまで1行も出力できません**。
  そのため「最初の1行が返るまでの時間」は Nested Loops より確実に遅くなります。
- プラン上の表示は **`Hash Match`** で、**上側の入力が build、下側が probe** です。
  演算子プロパティの `Hash Keys Build` / `Hash Keys Probe` でも確認できます。

### 5-2. メモリを大量に使う ← ここが最重要

**ハッシュ表はメモリ上に作られます。** つまり Hash Join は
**build 側の行数 × 行サイズにほぼ比例したメモリを要求します**。
これが Nested Loops / Merge との決定的な違いです。

```sql
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

-- 自然な形: build 側が Customers(12行)→ ハッシュ表はごく小さい
SELECT c.CustomerName, COUNT(*) AS 件数, SUM(o.Amount) AS 金額
FROM   dbo.OrdersBig AS o
INNER JOIN dbo.Customers AS c ON c.CustomerId = o.CustomerId
GROUP  BY c.CustomerName
OPTION (HASH JOIN, MAXDOP 1);

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
```

実行後、プランの **いちばん左の `SELECT` 演算子** をクリックしてプロパティを開き、
**`MemoryGrantInfo`** を展開してください。

| プロパティ | 意味 |
|---|---|
| `SerialRequiredMemory` | 直列実行で **最低限必要** な量(KB) |
| `SerialDesiredMemory` | 直列実行で **理想的な** 量(KB) |
| `RequiredMemory` | 実際の DOP での最低必要量 |
| `DesiredMemory` | 実際の DOP での理想量 |
| `RequestedMemory` | **実際に要求した量** |
| `GrantedMemory` | **実際に許可された量** |
| `MaxUsedMemory` | **実際に使った量**(2016+ の実際のプランで表示) |
| `GrantWaitTime` | メモリ許可を **待った秒数** |

`RequestedMemory` と `MaxUsedMemory` を比べるのが、この章の重要な読み方です。

### 5-3. build 側を間違えると破綻する

オプティマイザは「**小さいと推定したほう**」を build に選びます。
推定が外れて **大きいほうを build にしてしまう** と、巨大なハッシュ表を作ろうとして破綻します。

わざと逆にしてみましょう。`FORCE ORDER` を付けると、`FROM` に先に書いたテーブルが build 側になります。

```sql
SET STATISTICS TIME ON;

-- ✗ 100万行の OrdersBig を build 側にしてしまった場合
SELECT c.CustomerName, COUNT(*) AS 件数
FROM   dbo.OrdersBig AS o
INNER JOIN dbo.Customers AS c ON c.CustomerId = o.CustomerId
GROUP  BY c.CustomerName
OPTION (HASH JOIN, FORCE ORDER, MAXDOP 1);

SET STATISTICS TIME OFF;
```

この2つ(5-2 と 5-3)で **`RequestedMemory` を比べてください**。
build 側が 12 行のときは数百 KB〜数 MB、100万行のときは **数十 MB 以上** を要求します。
**同じ結果を返す同じ結合なのに、要求メモリが2桁変わる**わけです。

### 5-4. メモリが足りないときの3段階

SQL Server はメモリが足りなくても諦めません。段階的に劣化します。

| 段階 | 名称 | 内容 |
|---|---|---|
| 1 | **In-Memory Hash Join** | すべてメモリ内で完結。正常 |
| 2 | **Grace Hash Join** | ハッシュ表を複数パーティションに分け、**一部を tempdb に退避**(= スピル) |
| 3 | **Recursive Hash Join** | 退避したパーティションがまだ大きく、**さらに分割を繰り返す** |

さらに、ハッシュ値が極端に偏って分割しても小さくならない場合は
**ハッシュ ベイルアウト (hash bailout)** となり、内部的に別のアルゴリズムに切り替わります。
ここまで来ると性能は壊滅的です。

**段階2以降がすべて「スピル」**です。次節で正面から扱います。

---

## 6. 3つのアルゴリズムの比較

**この表がこの章の骨格**です。プランを見て「なぜこれが選ばれたのか」を説明するときの物差しになります。

| 観点 | Nested Loops | Merge Join | Hash Join |
|---|---|---|---|
| **向いているデータ量** | 外側が **小さい**(数行〜数千行) | **両側とも大きい** | **両側とも大きい**(特に片側が小さめ) |
| **インデックス** | **内側に必須**(無いと破綻) | **両側にソート順が欲しい** | **不要** |
| **入力のソート順** | 不要 | **必須**(無ければ Sort を挿入) | 不要 |
| **メモリ消費** | **ほぼゼロ** | **ほぼゼロ**(Sort が要るなら大) | **大**(build 側に比例) |
| **tempdb** | 使わない | 多対多のときワークテーブル | **スピル時に大量に使う** |
| **結合条件** | 等値・**非等値どちらでも可** | **等値が必須** | **等値が必須** |
| **出力順序** | 外側の順序を保つ | **結合キー順にソート済み** | **保証なし** |
| **最初の1行までの速さ** | **速い**(ブロックしない) | 中(両側の先頭が揃えば出せる) | **遅い**(build 完了まで出せない) |
| **並列との相性** | 良(ただし偏りやすい) | 中 | **良**(ハッシュ分割と相性抜群) |
| **コストの目安** | 外側行数 × 内側1回のコスト | 両入力の行数の和 | 両入力の行数の和 + メモリ |
| **破綻するとき** | 外側の推定が過小 | Sort が巨大 / 多対多 | **メモリ推定ミス → スピル** |

**判断のショートカット**

- プランに **`Nested Loops` があって、内側の実行回数が数万回以上** → まず疑う。
- プランに **`Sort` + `Merge Join`** が並んでいる → その `Sort` は本当に必要か?
  インデックスで消せないか?
- プランに **`Hash Match` があって黄色い警告アイコン** → スピルしている。7節へ。
- **どの演算子であれ、推定行数と実際の行数が桁違いなら、原因はそこ**
  ([27 統計情報とカーディナリティ推定](27_statistics_cardinality.md))。

---

## 7. メモリ許可 (Memory Grant) とスピル ★この章の最重要

### 7-1. 誰がメモリを予約するのか

クエリは実行を **始める前に** ワークスペースメモリを **予約(grant)** します。
予約を要求するのは、主に次の演算子です。

- **`Sort`**(`ORDER BY`、`Merge Join` の前処理、インデックス作成、`DISTINCT` の一部)
- **`Hash Match`**(Hash Join、Hash Aggregate、Hash Union)
- **`Optimized Nested Loops`** の暗黙のバッチソート
- 列ストア関連の一部演算子([30 列ストアインデックスとバッチモード](30_columnstore.md))

逆に言えば、**Nested Loops(ソート無し)や Index Seek はメモリ許可をほとんど必要としません**。
「メモリを食うクエリ」= **ソートしているか、ハッシュしているか** です。

### 7-2. 予約量はコンパイル時の「推定行数」で決まる

ここが本章と [27 統計情報とカーディナリティ推定](27_statistics_cardinality.md)・
[28 パラメータスニッフィング詳解](28_parameter_sniffing.md) の接続点です。

```
要求メモリ ≒ 推定行数 × 推定行サイズ × (演算子ごとの係数) × DOP に応じた補正
```

- **実行時の実際の行数ではなく、コンパイル時の推定行数**が使われます。
- 予約は **クエリ実行中ずっと保持** され、**途中で増減できません**
  (メモリ許可フィードバックが働く場合を除く。7-7 節)。
- 実際に使わなくても **確保しっぱなし** です。

つまり **推定が外れると、必ず次の2つのどちらかが起きます**。

| 推定 | 何が起きるか | 症状 |
|---|---|---|
| **過小推定** | 予約が小さすぎる → 入りきらない → **tempdb にスピル** | そのクエリが激遅になる |
| **過大推定** | 予約が大きすぎる → メモリを無駄に占有 | **他のクエリ**が `RESOURCE_SEMAPHORE` で待たされる |

**過小推定は自分が遅くなり、過大推定は他人を遅くする**。これが要点です。

### 7-3. スピルをわざと起こしてみる

`MAX_GRANT_PERCENT` クエリヒント(**2012 SP3 / 2014 SP2 / 2016+**)を使うと、
メモリ許可の上限を割合で強制できます。極端に小さくすればスピルを再現できます。

```sql
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

-- ① 正常: 100万行の Hash Aggregate。十分なメモリが許可される
SELECT COUNT_BIG(*) AS 件数
FROM   (SELECT DISTINCT OrderId, Amount FROM dbo.OrdersBig) AS x
OPTION (HASH GROUP, MAXDOP 1);

-- ② スピル: メモリ許可を上限1%に制限する
SELECT COUNT_BIG(*) AS 件数
FROM   (SELECT DISTINCT OrderId, Amount FROM dbo.OrdersBig) AS x
OPTION (HASH GROUP, MAXDOP 1, MAX_GRANT_PERCENT = 1);

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
```

② を **実際の実行プラン(`Ctrl`+`M`)** で実行すると:

- `Hash Match` に **黄色い三角の警告アイコン**が付きます。
- ツールチップ / プロパティに
  **`ハッシュ書き込みの警告` / `Hash Warning`**、あるいは
  **`スピルしたスレッド数 (Spilled Thread Count)`**、
  **`スピル レベル (SpillLevel)`**、`書き込みページ数 (SpilledDataSize)` が表示されます。
- `STATISTICS IO` に **`ワークテーブル`(Worktable)** の論理読み取りが現れます。
  **これが tempdb への往復**です。
- 経過時間が数倍〜十数倍に伸びます(環境により前後します)。

Hash **Join** でも同じことを確認できます。

```sql
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

SELECT COUNT_BIG(*) AS 件数
FROM   dbo.OrdersBig AS a
INNER JOIN dbo.OrdersBig AS b ON b.OrderId = a.OrderId
OPTION (HASH JOIN, MAXDOP 1, MAX_GRANT_PERCENT = 1);

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
```

`Sort` でも同様に **`ソートの警告` / `Sort Warning`** が出ます。

> ⚠️ `MAX_GRANT_PERCENT` は **学習と緊急避難のためのヒント**です。
> 本番で常用すると、データが増えたときに **必ずスピルする設定を焼き付ける**ことになります。
> 詳しくは9節(ヒントは最後の手段)。

### 7-4. スピルの見つけ方(4つの経路)

**(a) 実行プランの警告アイコン**

いちばん直接的です。実際のプランで `Hash Match` / `Sort` に警告が付いていないか見ます。
**推定プラン(`Ctrl`+`L`)にはスピル警告は出ません**(実行しないと分からないため)。

**(b) `sys.dm_exec_query_stats`(2016 SP2 / 2017 CU3 以降)**

キャッシュに残っているプランについて、スピルのページ数を集計できます。

```sql
SELECT TOP (20)
       qs.total_spills,                 -- 累計スピルページ数
       qs.last_spills,                  -- 直近実行のスピルページ数
       qs.max_spills,                   -- 最大
       qs.execution_count               AS 実行回数,
       qs.last_grant_kb                 AS 直近許可KB,
       qs.last_used_grant_kb            AS 直近実使用KB,
       qs.max_grant_kb                  AS 最大許可KB,
       SUBSTRING(st.text,
                 (qs.statement_start_offset/2) + 1,
                 ((CASE qs.statement_end_offset WHEN -1
                        THEN DATALENGTH(st.text)
                        ELSE qs.statement_end_offset END - qs.statement_start_offset)/2) + 1
       ) AS ステートメント
FROM   sys.dm_exec_query_stats AS qs
CROSS  APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
WHERE  qs.total_spills > 0
ORDER  BY qs.total_spills DESC;
```

- **`last_grant_kb` に対して `last_used_grant_kb` が極端に小さい**ものは **過大推定**の候補。
- **`total_spills` が大きい**ものは **過小推定**の候補。
- この2列を並べて見るだけで、メモリ許可の健康診断ができます。

**(c) 拡張イベント**([25 拡張イベント](25_extended_events.md))

リアルタイムに捕まえたいときはこちらです。イベント名を正確に覚えてください。

| イベント | 捕まえるもの |
|---|---|
| `sort_warning` | `Sort` のスピル |
| `hash_warning` | `Hash Match` のスピル/ベイルアウト |
| `exchange_spill` | **並列の Exchange 演算子** のスピル(8節) |

**(d) Query Store**([24 Query Store](24_query_store.md))

`sys.query_store_runtime_stats` の `avg_query_max_used_memory`(**2016+**)や
`avg_tempdb_space_used`(**2017+**)で、時系列の傾向を追えます。
「先月まで出ていなかったスピルが今月から出ている」という **回帰の検出** に向いています。

### 7-5. `sys.dm_exec_query_memory_grants` で「今」を見る

**実行中のクエリ**のメモリ許可を見る DMV です。長時間クエリの調査ではこれが主役になります。

```sql
SELECT mg.session_id                             AS セッション,
       mg.dop                                    AS DOP,
       mg.request_time                           AS 要求時刻,
       mg.grant_time                             AS 許可時刻,   -- NULL なら「まだ待っている」
       mg.requested_memory_kb                    AS 要求KB,
       mg.granted_memory_kb                      AS 許可KB,
       mg.required_memory_kb                     AS 最低必要KB,
       mg.used_memory_kb                         AS 現在使用KB,
       mg.max_used_memory_kb                     AS 最大使用KB,
       mg.ideal_memory_kb                        AS 理想KB,
       mg.query_cost                             AS 推定コスト,
       mg.timeout_sec                            AS タイムアウト秒,
       mg.wait_time_ms                           AS 待ちミリ秒,
       mg.is_next_candidate                      AS 次の候補か,
       mg.resource_semaphore_id                  AS セマフォID,
       st.text                                   AS クエリ
FROM   sys.dm_exec_query_memory_grants AS mg
CROSS  APPLY sys.dm_exec_sql_text(mg.sql_handle) AS st
ORDER  BY mg.requested_memory_kb DESC;
```

**判断基準**

| 見えたもの | 疑うこと |
|---|---|
| `grant_time` が **NULL** で `wait_time_ms` が大きい | メモリ待ち。**`RESOURCE_SEMAPHORE`** で詰まっている |
| `granted_memory_kb` ≫ `max_used_memory_kb` | **過大推定**。他クエリを締め出している |
| `granted_memory_kb` = `required_memory_kb` 付近 | 要求が削られている。スピルしている可能性 |
| `requested_memory_kb` が GB 級 | build 側の選択ミスか、推定行数の暴走 |

サーバー全体のワークスペースメモリの残量は、次で見ます。

```sql
SELECT resource_semaphore_id           AS セマフォID,
       target_memory_kb                AS 目標KB,
       max_target_memory_kb            AS 上限KB,
       total_memory_kb                 AS 合計KB,
       available_memory_kb             AS 空きKB,
       granted_memory_kb               AS 許可済みKB,
       grantee_count                   AS 実行中クエリ数,
       waiter_count                    AS 待機中クエリ数,      -- ← ここが 0 より大きいなら要注意
       timeout_error_count             AS タイムアウト回数,
       forced_grant_count              AS 強制許可回数
FROM   sys.dm_exec_query_resource_semaphores;
```

- `waiter_count > 0` が常態化しているなら、**メモリ許可がサーバーのボトルネック**です。
- `resource_semaphore_id = 0` が通常のクエリ、`1` が **小さいクエリ専用**のセマフォです。

### 7-6. 過大推定と `RESOURCE_SEMAPHORE`

[23 待機統計とボトルネック特定](23_wait_statistics.md) で扱う待機タイプのうち、
**`RESOURCE_SEMAPHORE`** はこの章と直結しています。

```sql
-- メモリ許可まわりの待機だけを見る
SELECT wait_type                       AS 待機タイプ,
       waiting_tasks_count             AS 待機回数,
       wait_time_ms                    AS 合計待機ミリ秒,
       max_wait_time_ms                AS 最大待機ミリ秒,
       signal_wait_time_ms             AS シグナル待機ミリ秒
FROM   sys.dm_os_wait_stats
WHERE  wait_type IN (N'RESOURCE_SEMAPHORE',
                     N'RESOURCE_SEMAPHORE_QUERY_COMPILE')
ORDER  BY wait_time_ms DESC;
```

- **`RESOURCE_SEMAPHORE`** … **クエリ実行用**のメモリ許可待ち。
  「1本の巨大な要求が枠を占有し、他のクエリが全員待たされている」状態。
- **`RESOURCE_SEMAPHORE_QUERY_COMPILE`** … **コンパイル用**メモリの待ち。別物です。
  アドホッククエリの大量発行([20 動的SQL](20_dynamic_sql.md))で起きがちです。

**`RESOURCE_SEMAPHORE` が上位に出たときの調査手順**

1. `sys.dm_exec_query_memory_grants` で **`requested_memory_kb` が突出したクエリ**を特定する。
2. そのクエリの実際のプランで **推定行数と実際の行数**を比べる。
3. 過大推定なら、統計の更新・`OPTION (RECOMPILE)`・クエリの書き換えで **推定を直す**。
4. どうしても直らない場合の最後の手段として `MAX_GRANT_PERCENT`、
   あるいは Resource Governor のワークロードグループで上限を設ける。

> ⚠️ **順序が大事です。** 「メモリが足りない → メモリを増やす」ではありません。
> **たいていの場合、足りないのはメモリではなく推定の精度**です。
> 推定を直せば、要求メモリは自然に適正化されます。

### 7-7. メモリ許可フィードバック(Adaptive Query Processing)

SQL Server は「前回の実行で実際に使った量」を覚えて、次回の許可量を補正する機能を持っています。
**Adaptive Query Processing / Intelligent Query Processing** の一部です。

| 版 | 機能 | 有効化の条件 |
|---|---|---|
| **2017** | **バッチモード** メモリ許可フィードバック | 互換性レベル **140** 以上 + バッチモード(列ストア) |
| **2019** | **行モード** メモリ許可フィードバック | 互換性レベル **150** 以上 |
| **2022** | **メモリ許可フィードバックの永続化**(Query Store に保存) | 互換性レベル **160** + Query Store 有効 |
| **2022** | **パーセンタイル** メモリ許可フィードバック | 同上 |

- **2019 より前**は行モード(通常のクエリ)には効きません。この章の例は基本的に行モードです。
- **2022 より前のフィードバックはプランキャッシュ上にしか無い**ため、
  **再コンパイルやサーバー再起動で忘れます**。2022 の永続化はこれを解決したものです。
- **パーセンタイル フィードバック**は、実行ごとに必要量が大きく振れるクエリ(まさに
  [28 パラメータスニッフィング](28_parameter_sniffing.md) の世界)で、
  平均ではなく直近の高いほうのパーセンタイルに合わせる改良です。

```sql
-- 互換性レベルの確認(変更はしない。確認のみ)
SELECT name AS データベース名, compatibility_level AS 互換性レベル
FROM   sys.databases
WHERE  name = N'SalesLearning';
```

> ⚠️ **クエリヒントを付けるとフィードバックは働きません**。
> `MAX_GRANT_PERCENT` / `MIN_GRANT_PERCENT` を書いた瞬間に、
> SQL Server が自分で学習して直す道を塞ぐことになります。これも「ヒントは最後の手段」の理由です。

---

## 8. 並列処理 (Parallelism)

### 8-1. 並列プランが選ばれる条件

2つの設定が門番をしています。

| 設定 | 既定値 | 意味 |
|---|---|---|
| **cost threshold for parallelism**(並列処理のコストしきい値) | **5** | **直列プランの推定コスト**がこの値を超えたら、並列プランも検討する |
| **max degree of parallelism (MAXDOP)** | **0**(= 制限なし) | 1つのクエリが使える **スレッド数の上限** |

現在値を確認します。**まず現在値を記録する**のがこの節の作法です。

```sql
SELECT name        AS 設定名,
       value       AS 設定値,
       value_in_use AS 実効値,
       description AS 説明
FROM   sys.configurations
WHERE  name IN (N'max degree of parallelism',
                N'cost threshold for parallelism');
```

判定の流れはこうです。

```
① まず直列プランを作る
② その推定コスト <= cost threshold for parallelism  → 直列プラン確定
③ 超えていれば並列プランも作り、コストが安いほうを採用
④ 採用された並列プランの DOP は実行時に決まる(MAXDOP と空きスレッド数の小さいほう)
```

- **既定の 5 は 1990年代のハードウェアを基準にした値**です。
  現代のサーバーでは「たいして重くないクエリまで並列化されてしまう」ため、
  **25〜50 程度へ引き上げる**のが広く行われている定石です。
  ただし **必ず自分のワークロードで計測してから**決めてください。
- **DOP は実行時に決まります**。同じプランでも、混雑していれば低い DOP で走ります。

実際に比べてみましょう。

```sql
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

-- ① 直列を強制
SELECT e.LastName, c.Region, COUNT(*) AS 件数, SUM(o.Amount) AS 金額
FROM   dbo.OrdersBig AS o
INNER JOIN dbo.Customers AS c ON c.CustomerId = o.CustomerId
INNER JOIN dbo.Employees AS e ON e.EmployeeId = o.EmployeeId
GROUP  BY e.LastName, c.Region
OPTION (MAXDOP 1);

-- ② オプティマイザに任せる(並列になるはず)
SELECT e.LastName, c.Region, COUNT(*) AS 件数, SUM(o.Amount) AS 金額
FROM   dbo.OrdersBig AS o
INNER JOIN dbo.Customers AS c ON c.CustomerId = o.CustomerId
INNER JOIN dbo.Employees AS e ON e.EmployeeId = o.EmployeeId
GROUP  BY e.LastName, c.Region;

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
```

- ① は **CPU 時間 ≒ 経過時間**。
- ② は **CPU 時間 > 経過時間**(合計 CPU は増え、実時間は短くなる)。
- ② のプランの演算子には **黄色い二重矢印のアイコン**(並列マーク)が付きます。
- **論理読み取り数はほとんど変わりません**。並列化は **同じ仕事を分担する**だけで、
  読むページ数を減らすわけではないからです。

> ⚠️ **並列は「CPU を余分に使って実時間を買う」取引**です。
> 1本のクエリは速くなっても、**サーバー全体のスループットは下がることがあります**。
> 同時実行が多い OLTP で並列プランが増えたら、それは黄信号です。

### 8-2. Exchange 演算子(Parallelism)

並列プランでスレッド間のデータを受け渡す演算子が **Exchange**(プラン上の表示は `Parallelism`)です。
プロパティの **`Logical Operation`** に3種類のいずれかが入ります。

| 表示 | 向き | 役割 |
|---|---|---|
| **Distribute Streams** | 直列 → 並列 | 1本のストリームを複数スレッドに **配る** |
| **Repartition Streams** | 並列 → 並列 | **配り直す**。結合キー/グループキーで再分配する |
| **Gather Streams** | 並列 → 直列 | 複数スレッドの結果を **1本に集める**。プランの左端近くに必ず1つある |

さらに **`Partitioning Type`** プロパティで「どう配るか」が分かります。

| 種類 | 内容 |
|---|---|
| **Hash** | 指定列のハッシュ値でスレッドを決める(**偏りの主犯**。8-4 節) |
| **Round Robin** | 順繰りに均等配分。偏りにくい |
| **Broadcast** | **全スレッドに全行を配る**。小さい入力にのみ使われる |
| **Range** | 値の範囲で分ける |
| **Demand** | 空いたスレッドが要求して取りに行く(パーティション表のスキャンなど) |

読み方のコツ:

- **`Repartition Streams` が多いプランは、配り直しのコストを払っています**。
  結合キーが揃っていない(適切なインデックスが無い)サインであることが多い。
- **`Gather Streams` の直後に `Sort` がある**なら、並列でソートしたものを
  順序付きでマージしている可能性があります(`Order By` プロパティの有無を見る)。
- Exchange 自身がバッファを持つため、**Exchange もスピルします**。
  拡張イベントの **`exchange_spill`** がそれです。
  出たら DOP を下げるか、そもそもの推定を直します。

### 8-3. `CXPACKET` と `CXCONSUMER` の違い

並列処理でいちばん誤解されている待機タイプです。
[23 待機統計とボトルネック特定](23_wait_statistics.md) と必ずセットで理解してください。

**分離される前(2016 SP2 / 2017 CU3 より前)**

- 並列スレッド間の待ちは **すべて `CXPACKET`** に計上されていました。
- そこには「**構造的に必ず発生する、まったく無害な待ち**」が大量に含まれていました。
  具体的には、**consumer(受け手)スレッドが producer(送り手)からのデータを待つ時間**です。
  これは並列が正常に動いていても必ず出ます。
- 結果として **`CXPACKET` が待機統計の1位になるのが当たり前**になり、
  「`CXPACKET` が多い → 並列が悪い → MAXDOP を 1 にしよう」という
  **誤った対処が世界中で横行**しました。

**分離された後(2016 SP2 / 2017 CU3 以降)**

| 待機タイプ | 誰が待っているか | 意味 |
|---|---|---|
| **`CXCONSUMER`** | **受け手 (consumer)** | **基本的に無害**。並列なら必ず出る。**そのまま無視してよい** |
| **`CXPACKET`** | **送り手 (producer)** 側など | **意味がある**。スレッド間の **偏り (skew)** や、遅いスレッドの存在を示唆する |

さらに **SQL Server 2019** では `CXSYNC_PORT` / `CXSYNC_CONSUMER` が追加され、
Exchange の同期待ちがさらに細分化されています。

```sql
-- 並列関連の待機を見る
SELECT wait_type                 AS 待機タイプ,
       waiting_tasks_count       AS 待機回数,
       wait_time_ms              AS 合計待機ミリ秒,
       wait_time_ms * 1.0 / NULLIF(waiting_tasks_count, 0) AS 平均待機ミリ秒,
       max_wait_time_ms          AS 最大待機ミリ秒
FROM   sys.dm_os_wait_stats
WHERE  wait_type LIKE N'CX%'
ORDER  BY wait_time_ms DESC;
```

**判断基準**

- **`CXCONSUMER` だけが大きい** → 並列は正常に働いている。**対処不要**。
- **`CXPACKET` が大きい** → 偏りか、並列プランが多すぎるか。
  → まず **`cost threshold for parallelism` を上げて、軽いクエリを直列に戻す** ことを検討する。
  → 個別のクエリなら **8-4 節の偏り**を調べる。
- **どちらであれ「`CXPACKET` が1位だから MAXDOP=1」は短絡**です。
  待機統計は「**待っている**」ことしか教えません。**遅いかどうかは別の指標で確認**してください。

> ⚠️ `sys.dm_os_wait_stats` はサーバー起動時からの累計です。
> 検証時は起点をそろえるため、開発環境でのみ `DBCC SQLPERF('sys.dm_os_wait_stats', CLEAR);` でリセットするか、
> **開始時と終了時の差分を取る**ようにしてください(**本番でのリセットは厳禁**)。

### 8-4. 並列処理の偏り (skew)

並列は **全スレッドが終わるまで完了しません**。
つまり **いちばん遅いスレッドが全体の時間を決めます**。

```
DOP 8 で 800万行を処理する場合

理想: 各スレッド 100万行ずつ  → 1スレッド分の時間で完了
偏り: 1スレッドに 700万行、残り7スレッドに 100万行を分け合う
      → 直列とほとんど変わらないうえ、Exchange のオーバーヘッドだけ増える
```

**主な原因**

1. **`Repartition Streams` の `Partitioning Type = Hash` で、偏った列に分配した**。
   `dbo.OrdersBig` の `Status`(`N'完了'` 95% / `N'保留'` 5%)のような列がまさにこれ。
   ハッシュ値が2種類しかなければ、**最大でも2スレッドにしか行が届きません**。
2. **Nested Loops の並列で、外側の分配が不均等**だった。
3. **統計の偏り**により、範囲分割の境界がずれた。

**プランでの見つけ方(手順)**

1. **実際の実行プラン(`Ctrl`+`M`)** で実行する。
2. 疑わしい演算子(Scan、Hash Match、Exchange の下側など)を **右クリック → プロパティ**。
3. **`Actual Number of Rows`(実際の行数)を展開**する。
   `Thread 0`, `Thread 1`, … とスレッド別の行数が並びます。
4. **`Thread 0` は調整スレッド(コーディネータ)** なので通常 0 行です。無視します。
5. **`Thread 1` 以降の行数を見比べる**。数倍以上の開きがあれば **偏っています**。

同じ要領で `Actual Time Statistics` を展開すれば、スレッド別の経過時間も見られます。

**実行中のクエリ**なら、`sys.dm_exec_query_profiles`(**2014+**)でライブに見られます。

```sql
-- 別セッションで長時間クエリを走らせながら実行する
SELECT p.session_id            AS セッション,
       p.node_id               AS ノードID,
       p.physical_operator_name AS 演算子,
       p.thread_id             AS スレッド,
       p.row_count             AS 処理済み行数,
       p.estimate_row_count    AS 推定行数
FROM   sys.dm_exec_query_profiles AS p
WHERE  p.session_id = 99                   -- 調べたいセッションIDに変える
ORDER  BY p.node_id, p.thread_id;
```

- 同じ `node_id`(= 同じ演算子)の中で **`row_count` がスレッドごとに大きく違えば偏り**です。
- **2016 SP1+ では軽量プロファイリング**が使えるため、本番でも比較的安全に観測できます
  ([26 DMVによる調査](26_dmv_investigation.md))。

**偏りへの対処**

- 分配キーになっている **偏った列を結合・グループ化のキーから外せないか** 検討する。
- **インデックスを追加**して `Repartition Streams` 自体を不要にする。
- 効果が無いなら **そのクエリだけ `OPTION (MAXDOP 1)`** にする(サーバー全体を変えない)。

> ⚠️ 偏りは **データの中身に依存する**ため、環境やデータの分布によって
> 出たり出なかったりします。ここで身につけるべきは「偏っているか **確かめる手順**」です。

### 8-5. MAXDOP の設定粒度(★戻す手順とセットで)

MAXDOP は **4つの粒度**で指定でき、**狭いほうが優先**されます。

| 粒度 | 構文 | 影響範囲 |
|---|---|---|
| ① **サーバー** | `sp_configure 'max degree of parallelism'` | インスタンス全体 |
| ② **データベース スコープ構成**(**2016+**) | `ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP = n` | そのデータベース |
| ③ **Resource Governor** | ワークロードグループの `MAX_DOP` | そのグループのセッション |
| ④ **クエリヒント** | `OPTION (MAXDOP n)` | **そのクエリ1本だけ** |

**優先順位**: ④ クエリヒント > ③ Resource Governor(上限として作用) > ② DB スコープ > ① サーバー。

**学習・検証では原則 ④ を使ってください。** 他人に影響しないからです。

#### ② データベース スコープ構成を試す(必ず戻す)

```sql
-- ★ STEP 1: 変更前の値を必ず記録する
SELECT configuration_id AS ID,
       name             AS 設定名,
       value            AS 現在値,
       value_for_secondary AS セカンダリ用
FROM   sys.database_scoped_configurations
WHERE  name = N'MAXDOP';
-- ↑ ここに出た「現在値」をメモしておく(既定は 0 = サーバー設定に従う)

-- ★ STEP 2: 変更する(このデータベースだけ直列にする)
ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP = 1;

-- ★ STEP 3: 効果を確認する(8-1 の ② が直列になるはず)
SELECT e.LastName, c.Region, COUNT(*) AS 件数, SUM(o.Amount) AS 金額
FROM   dbo.OrdersBig AS o
INNER JOIN dbo.Customers AS c ON c.CustomerId = o.CustomerId
INNER JOIN dbo.Employees AS e ON e.EmployeeId = o.EmployeeId
GROUP  BY e.LastName, c.Region;

-- ★ STEP 4: 【必須】元に戻す
ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP = 0;   -- STEP 1 で記録した値に戻す

-- ★ STEP 5: 戻ったことを確認する
SELECT name AS 設定名, value AS 現在値
FROM   sys.database_scoped_configurations
WHERE  name = N'MAXDOP';
```

> ⚠️ **STEP 4 を忘れると、以降この教材のすべての並列の例が再現しなくなります。**
> STEP 2 を実行したら、**同じバッチの中に STEP 4 も書いておく**のが安全な習慣です。

#### ① サーバー設定を変える場合(共有環境では実行しない)

```sql
-- ★ STEP 1: 変更前の値を必ず記録する
SELECT name AS 設定名, value AS 設定値, value_in_use AS 実効値
FROM   sys.configurations
WHERE  name IN (N'max degree of parallelism', N'cost threshold for parallelism');
-- 例: max degree of parallelism = 0 / cost threshold for parallelism = 5 と記録

-- ★ STEP 2: 変更する
EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;
EXEC sp_configure 'cost threshold for parallelism', 50;
RECONFIGURE;

-- ★ STEP 3: 効果を確認(コスト 50 以下のクエリは直列になる)

-- ★ STEP 4: 【必須】STEP 1 で記録した元の値に戻す
EXEC sp_configure 'cost threshold for parallelism', 5;   -- ← 記録した値
RECONFIGURE;
EXEC sp_configure 'show advanced options', 0;
RECONFIGURE;

-- ★ STEP 5: 戻ったことを確認する
SELECT name AS 設定名, value AS 設定値, value_in_use AS 実効値
FROM   sys.configurations
WHERE  name IN (N'max degree of parallelism', N'cost threshold for parallelism');
```

> ⚠️ **`sp_configure` はインスタンス全体に効きます。**
> 共有の開発サーバーや本番では **絶対に実行しないでください**。
> 自分専用のローカル環境でのみ、**上の STEP 1 と STEP 4 をセットで**実行すること。

#### MAXDOP の値の決め方(一般的な出発点)

- 論理プロセッサが **8 以下** … MAXDOP = プロセッサ数以下
- 論理プロセッサが **8 超** … MAXDOP = **8** から始める
- NUMA 構成なら、**1つの NUMA ノードの論理プロセッサ数を超えない**ようにする
- **SQL Server 2019 以降のセットアップは、この目安に沿った値を自動で提案**します
- OLTP 中心なら低め(1〜4)、DWH/バッチ中心なら高め

いずれも **出発点**です。決めたら必ずワークロードで計測して調整してください。

### 8-6. 並列を抑止すべきケース

| ケース | 理由 |
|---|---|
| **短時間の OLTP クエリが並列化されている** | 並列化の準備コスト(スレッド確保・Exchange)のほうが高くつく。`cost threshold` を上げる |
| **`CXPACKET` が高く、偏りが確認できた** | 分担できていない。そのクエリだけ `MAXDOP 1` |
| **同時実行数が多く、ワーカースレッドが枯渇** | `THREADPOOL` 待機が出る。DOP を下げて1クエリあたりの消費を抑える |
| **Exchange のスピル(`exchange_spill`)が出る** | 並列のオーバーヘッドが逆効果 |
| **スカラー UDF を含むクエリ**(2019 未満) | そもそも **プラン全体が直列化**される。2019+ のスカラー UDF インライン化で改善 |
| **結果の順序が揺れて困る** | 並列では `ORDER BY` が無い限り順序は不定。ただし **これは並列でなくても保証されない** |

**抑止の方法は、影響範囲の狭いものから順に試すのが鉄則**です。

```
① そのクエリだけ OPTION (MAXDOP 1)
② そのデータベースだけ ALTER DATABASE SCOPED CONFIGURATION
③ サーバーの cost threshold for parallelism を上げる
④ サーバーの MAXDOP を変える   ← いちばん影響が大きい。最後
```

---

## 9. 結合ヒントと FORCE ORDER は最後の手段

### 9-1. 書き方

**クエリレベル(`OPTION` 句)** — そのクエリの **すべての結合**に効きます。

```sql
SELECT ...
FROM   ...
OPTION (LOOP JOIN);      -- または MERGE JOIN / HASH JOIN
```

複数を並べると「この中から選べ」という意味になります(全禁止よりは穏やか)。

```sql
OPTION (HASH JOIN, MERGE JOIN);   -- Nested Loops だけを除外する
```

**結合レベル(`FROM` 句)** — その1箇所の結合だけに効きます。

```sql
SELECT c.CustomerName, COUNT(*) AS 件数
FROM   dbo.OrdersBig AS o
INNER HASH JOIN dbo.Customers AS c ON c.CustomerId = o.CustomerId
GROUP  BY c.CustomerName;
```

**`FORCE ORDER`** — `FROM` に書いた順序どおりに結合させます。

```sql
OPTION (FORCE ORDER);
```

> ⚠️ **見落としやすい重要な副作用**: **結合レベルの結合ヒント(`INNER HASH JOIN` など)を書くと、
> そのクエリ全体に `FORCE ORDER` が暗黙に適用されます。**
> 「アルゴリズムだけ指定したつもりが、結合順序まで固定していた」という事故が起きます。
> 順序を固定したくないなら、`OPTION (HASH JOIN)` のクエリレベルヒントを使ってください。

### 9-2. なぜ「最後の手段」なのか

ヒントは **オプティマイザの判断を禁止する命令**です。提案ではありません。

1. **将来のデータ変化に適応できなくなる。**
   今日は 12 行の `Customers` が3年後に 500万行になっても、
   `OPTION (LOOP JOIN)` は Nested Loops を選び続けます。
   **ヒントは「今日のデータ分布」を永久に焼き付ける行為**です。
2. **原因を隠す。**
   結合方式が間違っているのは、ほぼ常に **推定行数が間違っている**からです。
   ヒントは症状を抑えるだけで、**同じ統計の誤りが他のクエリでも悪さをし続けます**。
3. **将来のバージョンアップの恩恵を受けられない。**
   Adaptive Join(10節)やメモリ許可フィードバック(7-7 節)といった改良は、
   **オプティマイザに選択の余地があるときだけ**働きます。ヒントはその余地を奪います。
4. **エラーで止まることがある。**
   ヒントで指定した方式が **物理的に不可能**な場合(例: 非等値結合に `MERGE JOIN`)、
   クエリは実行できずエラーになります。データが変わって条件が変われば、
   **ある日突然クエリが落ちる**ということです。
5. **`FORCE ORDER` は特に危険。**
   結合順序はテーブルが増えるほど爆発的に選択肢が増える部分で、
   オプティマイザがいちばん価値を発揮する場所です。そこを人手で固定するのは最後の最後。

### 9-3. ヒントに手を伸ばす前にやること(順番)

```
① 統計を更新する                       27章
② 推定行数と実際の行数の乖離を特定する    18章 / 27章
③ SARGable に書き換える                18章
④ インデックスを足す/直す               18章
⑤ 中間結果を一時テーブルに落として統計を持たせる   15章
⑥ OPTION (RECOMPILE) / OPTIMIZE FOR    28章
⑦ Query Store でプランを固定する        24章
────────────────────────────
⑧ ここではじめて結合ヒント            ← 本節
```

⑦ の **Query Store のプラン強制**は、ヒントより優先して検討する価値があります。
**クエリのソースコードを書き換えずに**プランを固定でき、
**後から強制を解除できる**からです([24 Query Store](24_query_store.md))。

### 9-4. それでもヒントを使うなら

- **必ずコメントで「なぜ・いつ・誰が」を残す**。
  ヒントは数年後に必ず「これ何?」となります。
- **見直す期限を決める**。「データ量が10倍になったら再評価」など。
- **ヒントを外したときのプランを、外す前に記録しておく**。

```sql
-- 2026-07-01 田中: 統計を FULLSCAN 更新しても Customers 側の推定が
--   1行に張り付き Nested Loops が選ばれ 30秒→ヒントで 0.4秒。
--   Customers が 10万行を超えたら要再評価。ticket #1234
SELECT ...
OPTION (HASH JOIN);
```

---

## 10. Adaptive Join(適応結合・2017+)

### 10-1. 何を解決する機能か

ここまでの話の根っこには **「結合方式はコンパイル時に決めるしかない」** という制約がありました。
**Adaptive Join** はこの制約を部分的に外します。

```
【従来】コンパイル時に Hash か Loops かを決める → 推定が外れたら破綻

【Adaptive Join】
   build フェーズを実行して「実際の行数」を数える
        ↓
   実際の行数 < しきい値  → Nested Loops に切り替えて実行
   実際の行数 >= しきい値 → そのまま Hash Join で実行
```

- **実際の行数を見てから決める**ので、推定ミスに強くなります。
- プラン上は **`Adaptive Join`** という1つの演算子として表示され、
  プロパティに **`Adaptive Threshold Rows`(しきい値行数)**、
  **`Actual Join Type`(実際に選ばれた方式)**、`Is Adaptive = True` が出ます。
- 実際のプランを見ると、**選ばれなかったほうの枝の行数が 0** になっています。

### 10-2. 使える条件(ここが重要)

| 版 | 条件 |
|---|---|
| **2017** | 互換性レベル **140** 以上 + **バッチモード**。つまり **列ストアインデックスが関与**する必要がある |
| **2019** | 互換性レベル **150** 以上 + **行ストアのバッチモード (Batch Mode on Rowstore)** でも可 |

- **エディションの制限**: 列ストアインデックスや行ストアのバッチモードは
  **Enterprise / Developer / Evaluation** が主対象です
  (Standard でも一部利用できますが、DOP などに制限があります)。
- **本教材の `dbo.OrdersBig` は行ストアのみ**なので、そのままでは Adaptive Join は現れません。
  **[30 列ストアインデックスとバッチモード](30_columnstore.md)** で
  `dbo.SalesFact` に列ストアを作ったあとに、改めて観察するのが自然な流れです。
- コストとしては、**Hash 用のメモリ許可を確保したうえで Nested Loops に切り替わることがある**ため、
  「Nested Loops なのにメモリを予約している」状態になりえます。
  つまり **万能ではなく、メモリ許可の観点では保守的**です。

### 10-3. 関連する Intelligent Query Processing 機能

Adaptive Join は「適応型クエリ処理」の一部です。この章に関係するものを整理します。

| 機能 | 版 | 内容 |
|---|---|---|
| **バッチモード メモリ許可フィードバック** | 2017 | 使用実績で許可量を補正 |
| **Adaptive Join** | 2017 | Hash / Loops を実行時に選択 |
| **Interleaved Execution** | 2017 | 複数ステートメント TVF の実行結果を見てから後続を最適化 |
| **行モード メモリ許可フィードバック** | 2019 | 通常のクエリにも適用 |
| **Batch Mode on Rowstore** | 2019 | 列ストア無しでもバッチモード |
| **メモリ許可フィードバックの永続化 / パーセンタイル** | 2022 | Query Store に保存、振れ幅に対応 |
| **DOP フィードバック** | 2022 | 並列度を実績から自動調整 |

---

## 11. 後片付け

**この章で作ったインデックスは必ず削除し、設定は必ず元に戻してください。**

```sql
-- ① インデックスを削除して、初期状態(PK_OrdersBig のみ)に戻す
DROP INDEX IF EXISTS IX_OrdersBig_CustomerId ON dbo.OrdersBig;
DROP INDEX IF EXISTS IX_OrdersBig_EmployeeId ON dbo.OrdersBig;
DROP INDEX IF EXISTS IX_OrdersBig_OrderDate  ON dbo.OrdersBig;

-- ② 確認: PK_OrdersBig(CLUSTERED)だけが残っていれば OK
SELECT i.name AS インデックス名, i.type_desc AS 種別
FROM   sys.indexes AS i
WHERE  i.object_id = OBJECT_ID('dbo.OrdersBig')
  AND  i.index_id > 0
ORDER  BY i.index_id;

-- ③ データベース スコープ構成が既定に戻っていることを確認
SELECT name AS 設定名, value AS 現在値
FROM   sys.database_scoped_configurations
WHERE  name = N'MAXDOP';          -- 0(= サーバー設定に従う)なら OK

-- ④ サーバー設定を触ったなら、元の値に戻っていることを確認
SELECT name AS 設定名, value AS 設定値, value_in_use AS 実効値
FROM   sys.configurations
WHERE  name IN (N'max degree of parallelism', N'cost threshold for parallelism');
```

> ⚠️ 途中でおかしくなったら、`sample-db/03_bulk_data.sql` を再実行すれば
> `dbo.OrdersBig` を丸ごと作り直せます(小さいテーブルには影響しません)。
> ただし **サーバー設定は元に戻りません**。設定は必ず自分で戻してください。

---

## よくあるつまずき

- **「Nested Loops は遅い」と覚えてしまう** → 外側が小さく内側にインデックスがあれば最速。
  遅いのは **外側の推定が過小で、実際は大量に流れてきたとき**。
- **「Hash Join は速い」と覚えてしまう** → メモリを大量に要求する。
  build 側を間違えると要求が2桁増え、スピルすれば tempdb を殴り続ける。
- **Merge Join を選んだら遅くなった** → `Sort` が入っていないか確認する。
  **ソート込みの Merge は Hash より高い**のが普通。
- **プランに `Sort` があるのに気づかない** → メモリ許可の主犯はたいてい `Sort` と `Hash Match`。
- **スピル警告を見落とす** → **推定プラン(`Ctrl`+`L`)にはスピル警告は出ない**。
  必ず **実際のプラン(`Ctrl`+`M`)** で確認する。
- **メモリが足りないからメモリを増やす** → たいていの原因は **推定の誤り**。
  `granted_memory_kb` と `max_used_memory_kb` を比べて、まず推定を疑う。
- **`CXPACKET` が1位だから MAXDOP=1 にする** → 2017+ では `CXCONSUMER`(無害)が分離されている。
  `CXPACKET` 側だけを見て、さらに **偏りの有無を実際のプランで確認**してから決める。
- **並列にしたのに論理読み取り数が減らない** → 当然。並列は **仕事を分担**するだけで、
  読むページ数は変わらない。減らしたいならインデックス(18章)。
- **並列なのに速くならない** → スレッド間の **偏り (skew)**。
  演算子プロパティの `Actual Number of Rows` をスレッド別に展開して確認する。
- **`INNER HASH JOIN` と書いたら結合順序まで変わった** → **結合レベルのヒントは
  暗黙に `FORCE ORDER` を適用する**。順序を固定したくなければ `OPTION (HASH JOIN)` を使う。
- **ヒントで直したので解決した気になる** → 原因(推定の誤り)は残ったまま。
  データが変わった日に、今度は逆方向に壊れる。
- **`MAXDOP` を変えたまま戻し忘れる** → 以降のすべての検証が再現しなくなる。
  **変更と復元は必ず同じバッチに書く**。

## この章のまとめ

- **論理結合(INNER/LEFT…)と物理演算子(Loops/Merge/Hash)は別物**。
  同じ `INNER JOIN` が、**流れる行数とインデックス**で3通りに実行される。
- **Nested Loops** … 外側の行ごとに内側を引く。**外側が小さい・内側にインデックス・1回の取得が少ない**、
  この3条件が揃ってはじめて最速。**非等値結合で使える唯一の方式**。
- **Merge Join** … **両側がソート済み**なら最強。**Sort が要るなら一転して高コスト**。
  **多対多**では tempdb のワークテーブルを使う。
- **Hash Join** … build 側でハッシュ表、probe 側を流す。**ソートもインデックスも不要**で大量データ向き。
  **メモリを大量に使う**。**build 側の選択を誤ると破綻**する。
- **6節の比較表**(データ量・インデックス・ソート順・メモリ・tempdb・結合条件)が判断の物差し。
- **メモリ許可は「コンパイル時の推定行数」で決まり、実行中は変えられない**。
  - **過小推定 → tempdb にスピル**(自分が遅くなる)。
  - **過大推定 → 他クエリが `RESOURCE_SEMAPHORE` で待つ**(他人を遅くする)。
  - 見つけ方: **実際のプランの警告アイコン** / `sys.dm_exec_query_memory_grants` /
    `sys.dm_exec_query_stats` の `total_spills`・`last_grant_kb`・`last_used_grant_kb` /
    拡張イベント `sort_warning`・`hash_warning`・`exchange_spill`。
  - **2017 バッチモード / 2019 行モード / 2022 永続化・パーセンタイル** のメモリ許可フィードバック。
    **ヒントを書くとフィードバックは働かない**。
- **並列**は `cost threshold for parallelism`(既定5)と `MAXDOP`(既定0)が門番。
  **CPU 時間 > 経過時間なら並列**。並列は **CPU を余分に払って実時間を買う取引**。
- **Exchange** は `Distribute` (直列→並列) / `Repartition` (並列→並列) / `Gather` (並列→直列)。
  `Partitioning Type = Hash` は **偏りの主犯**。
- **`CXCONSUMER`(受け手・無害)と `CXPACKET`(送り手・意味あり)** は 2016 SP2 / 2017 CU3 で分離された。
  **「`CXPACKET` が多い → MAXDOP=1」は誤り**。
- **偏り (skew)** は、演算子プロパティの **`Actual Number of Rows` をスレッド別に展開**して見つける。
  `Thread 0` はコーディネータなので除く。
- **MAXDOP は クエリヒント > Resource Governor > DB スコープ > サーバー** の順に狭い。
  **検証は必ずいちばん狭い `OPTION (MAXDOP n)` から**。設定を変えたら **必ず戻す**。
- **結合ヒントと `FORCE ORDER` は最後の手段**。**今日のデータ分布を永久に焼き付ける**行為であり、
  原因(推定の誤り)を隠し、将来の最適化の恩恵も断つ。
  **結合レベルのヒントは暗黙に `FORCE ORDER` を適用する**点に特に注意。
- **Adaptive Join**(2017 バッチモード / 2019 行ストアのバッチモード)は、
  **build を実行してから Hash か Loops かを決める**。推定ミスへの保険。

➡ 演習: [exercises/29_join_algorithms_parallelism.md](../exercises/29_join_algorithms_parallelism.md)
