# 25 拡張イベント (Extended Events)

> **このトピックのゴール**: SQL Server の「今、内部で何が起きているか」を、
> **本番環境に流したまま**捕まえられるようになる。
> 拡張イベント(XEvent)の構成要素 —— **イベント / アクション / 述語 / ターゲット / セッション** —— を理解し、
> `CREATE EVENT SESSION` を自分で書けるようになる。
> そして最大の関門である **「捕まえた XML を表形式に読み解く」** を、
> 遅いクエリ・**デッドロック**・ブロッキング・エラーの4つの実用例で身につける。
>
> **前提**: [24 Query Store](24_query_store.md) までを済ませていること。
> ブロッキングとデッドロックの「発生の仕組み」は [19 トランザクションと分離レベル](19_transactions_isolation.md) で、
> 待機の読み方は [23 待機統計とボトルネック特定](23_wait_statistics.md) で扱いました。
> **本章はその「捕捉方法」**、つまり「起きた瞬間の証拠を自動で残す」側を担当します。

すべての例は先頭で `USE SalesLearning;` を実行済みとします。

> ⚠️ **本章はサーバーレベルのオブジェクトを作ります**
> `CREATE EVENT SESSION ... ON SERVER` は **インスタンス全体**に作られるオブジェクトです
> (データベース単位ではありません)。必要な権限は **`ALTER ANY EVENT SESSION`** と、
> 結果を読むための **`VIEW SERVER STATE`**(SQL Server 2022 以降は `VIEW SERVER PERFORMANCE STATE` でも可)です。
>
> 作ったセッションは **明示的に `DROP` するまで残り続けます**。
> 本章と演習では、作成したものを必ず最後に `DROP EVENT SESSION` するところまで書きます。
> **作りっぱなしのセッションは、忘れたころにディスクとCPUを食う**ので、必ず片付けてください。

---

## 1. なぜ拡張イベントなのか — Profiler を本番で使ってはいけない理由

### 1-1. 3つの世代

| 世代 | 仕組み | 現在の位置づけ |
|---|---|---|
| **SQL Server Profiler**(GUI) | サーバーが発生させたイベントを **rowset プロバイダ**でクライアントへ送る | **本番禁止**。SQL Server 2012 で非推奨(deprecated)と発表済み |
| **サーバーサイドトレース**(`sp_trace_create`) | サーバー側でファイルに直接書く。Profiler より軽い | 同じく非推奨。新規に選ぶ理由はない |
| **拡張イベント**(XEvent) | イベント発生地点で **述語を評価してから**収集し、メモリバッファ経由で **非同期**にターゲットへ配る | **これが現行**。SQL Server 2008 で導入、2012 で GUI と機能網羅が完成 |

> ⚠️ **バージョン情報**: SQL Trace と SQL Server Profiler(データベースエンジン向け)は
> **SQL Server 2012 で非推奨**とアナウンスされています。まだ同梱されていますが、
> **新しいイベントは XEvent にしか追加されません**(Query Store、列ストア、インメモリ OLTP など、
> 2012 以降の機能の内部イベントは Profiler からは一切見えません)。

### 1-2. Profiler が本番で危険な、具体的な理由

1. **フィルタしても「取ってから捨てている」**
   Profiler の GUI でフィルタを掛けても、多くの場合 **イベントはサーバーで生成され、クライアントへ送られてから**
   捨てられます。「1秒以上のクエリだけ」と設定しても、**全クエリ分のイベント生成コストは掛かっています**。
2. **rowset プロバイダは同期的**
   GUI がイベントを消費しきれないと、**SQL Server 側のワーカースレッドが待たされます**。
   ネットワークが遅い、クライアントPCが重い —— それだけで **本番のクエリが遅くなります**。
3. **列を足すほど重くなる**
   `TextData` や `Showplan XML` を含めると、1イベントあたりの生成コストが跳ね上がります。

これに対して XEvent は、

- **述語(predicate)をイベント発生地点で評価**し、条件に合わないイベントは **そもそも組み立てません**。
  「1秒以上のクエリだけ」と書けば、1ミリ秒のクエリには **ほぼゼロコスト**です。
- 収集後は **メモリバッファに置いて非同期にディスパッチ**するため、ワーカースレッドを待たせません。
- 1イベントあたりのオーバーヘッドは **CPU 数マイクロ秒オーダー**(公称値。環境により前後する目安)。

> ⚠️ ただし **XEvent なら何でも安全、ではありません**。
> `query_post_execution_showplan`(実行プランを丸ごと取るイベント)のような
> **本質的に高コストなイベント**は、XEvent でも本番で流してはいけません(第12節)。
> 「軽いのは **フィルタされた XEvent**」であって、「XEvent という仕組み」ではない、という理解が正確です。

### 1-3. Query Store との使い分け([24章](24_query_store.md))

| | Query Store | 拡張イベント |
|---|---|---|
| 粒度 | クエリ単位の **集計**(実行回数・平均/最大) | **1イベント1行**の生ログ |
| 対象 | クエリの実行とプラン | クエリ以外も(ロック、エラー、ログイン、待機…) |
| 保持 | DB内に永続化。自動 | 自分でターゲットとサイズを設計する |
| 得意 | 「先週より遅くなったクエリは?」 | 「**あの瞬間に何が起きたか**」 |

**傾向は Query Store、事件は拡張イベント**と覚えると迷いません。
「毎日15時だけ遅い」は Query Store で当たりを付け、
「15時に何が起きているか」を XEvent で押さえる、という流れが実務の定石です。

## 2. 構成要素 —— 5つの用語

拡張イベントは次の5つの部品でできています。**この5つが分かれば `CREATE EVENT SESSION` は読めます。**

```
┌─ セッション (EVENT SESSION) ──────────────────────────────┐
│                                                          │
│   イベント ── 述語(WHERE) ── アクション(ACTION)          │
│     ↓ 条件に合ったものだけ                                │
│   ┌──────────── メモリバッファ(非同期) ───────────┐       │
│   └──────────────────┬───────────────────────────┘       │
│                      ↓                                   │
│   ターゲット (ring_buffer / event_file / histogram …)      │
└──────────────────────────────────────────────────────────┘
```

### 2-1. イベント (event)

**「これが起きたら教えて」という発火点**です。`sql_statement_completed`(1文が完了した)、
`xml_deadlock_report`(デッドロックが検出された)など。
イベントには **標準で付いてくる列(データ列)** があります。
例えば `sql_statement_completed` なら `duration` / `cpu_time` / `logical_reads` / `row_count` / `statement` など。

### 2-2. アクション (action)

**「発火したときに、ついでに一緒に採ってきてほしい追加情報」** です。
`sqlserver.sql_text`(バッチ全文)、`sqlserver.session_id`、`sqlserver.database_name`、
`sqlserver.client_app_name`、`sqlserver.username`、`sqlserver.plan_handle` など。

> ⚠️ **アクションはタダではありません。** アクションは **イベントが発火した直後に同期的に実行**され、
> 収集元(スタックの現在位置)から値を取ってきます。特に `sqlserver.sql_text` や
> `sqlserver.tsql_stack`、`sqlserver.plan_handle` は相応のコストが掛かります。
> **「あると便利」ではなく「これが無いと調査できない」ものだけ**を付けてください。

### 2-3. 述語 (predicate) = `WHERE`

**フィルタ**です。**拡張イベントの心臓部**であり、本番で使えるかどうかはここで決まります。

```sql
WHERE ([duration] > 1000000 AND [sqlserver].[database_name] = N'SalesLearning')
```

述語には2種類の使い方があります。

- **述語比較 (pred_compare)** — `>` `=` `<>` などの比較演算子、
  または `sqlserver.equal_i_sql_unicode_string(...)` のような関数形式(SSMS の GUI が生成するのはこちら)。
- **述語ソース (pred_source)** — イベント自身の列以外の値をフィルタ条件にできるもの。
  `sqlserver.database_name`、`sqlserver.session_id`、`sqlserver.is_system`、`sqlserver.client_app_name` など。

> ⚠️ **述語は左から順に評価され、短絡します(short-circuit)。**
> `WHERE (A AND B)` で A が偽なら B は評価されません。
> したがって **安くて選択性の高い条件を左に書く**のが鉄則です。
> `duration > 1000000`(イベント自身の列。ほぼタダ)を先に、
> `database_name = N'...'`(述語ソース。文字列比較)を後に、が定石です。

### 2-4. ターゲット (target)

**集めたイベントの置き場**です。次節で詳しく扱います。1セッションに複数付けられます。

### 2-5. セッション (session)

上記をひとまとめにした **設定の入れ物**です。作っただけでは動かず、
`ALTER EVENT SESSION ... STATE = START` で開始します。

> **「定義」と「実行中」は別物**です。ここは頻出のつまずきポイントです。
> - 定義(永続。停止中でも見える): `sys.server_event_sessions` とその関連ビュー
> - 実行中(メモリ上): `sys.dm_xe_sessions` / `sys.dm_xe_session_targets`
>
> `sys.dm_xe_sessions` に出てこない = **止まっている**、ということです。

## 3. ターゲットの使い分け

| ターゲット | 保存先 | 永続性 | 得意なこと | 主なオプション |
|---|---|---|---|---|
| **package0.ring_buffer** | メモリ | **揮発**(停止・再起動で消える) | 手軽な確認。学習・調査の第一歩 | `max_memory`(KB), `max_events_limit`(既定 1000) |
| **package0.event_file** | ディスク(`.xel`) | **永続** | **本番の常設監視**。あとから何度でも読める | `filename`, `max_file_size`(MB), `max_rollover_files` |
| **package0.histogram** | メモリ | 揮発 | **集計だけ**。「どの値が何回か」を数える。個々のイベントは残らない=最軽量級 | `filtering_event_name`, `source`, `source_type`(0=データ列 / 1=アクション。既定 1) |
| **package0.event_counter** | メモリ | 揮発 | **件数だけ**。イベントの中身を一切保持しない=**最軽量** | (なし) |
| **package0.pair_matching** | メモリ | 揮発 | 「開始したのに終わっていない」ものだけを残す | `begin_event`, `begin_matching_columns`, `end_event`, `end_matching_columns` |

### 3-1. ring_buffer — 手軽だが揮発、そして落とし穴あり

```sql
ADD TARGET package0.ring_buffer (SET max_memory = 4096, max_events_limit = 1000)
```

- リング(円環)なので **古いイベントから上書き**されます。`max_events_limit = 0` で無制限(メモリ次第)。
- **セッションを止めた瞬間に消えます。** 「結果を見る前に `STOP` してしまった」は最頻出の事故です。

> ⚠️ **ring_buffer の既知の落とし穴**: `target_data` として返される XML には
> **サイズ上限(おおむね 4 MB)があり、超えると途中で切れます**。
> 切れた XML は `CAST(... AS XML)` で **パースエラーになる**ことがあります
> (`XML 解析: 行 N、文字 M、予期しないファイルの終わり` など)。
> `<RingBufferTarget truncated="1" ...>` の `truncated` 属性が `1` なら切り捨てが起きているサインです。
> **`max_events_limit` を 100〜1000 程度に抑える**か、`event_file` に切り替えてください。

### 3-2. event_file — 本番はこれ

```sql
ADD TARGET package0.event_file
(
    SET filename           = N'C:\XE\xe_slow_queries.xel',
        max_file_size      = 50,      -- MB。既定は 1 GB
        max_rollover_files = 5        -- 世代数
)
```

- 実際に作られるファイル名は **`xe_slow_queries_0_133700000000000000.xel`** のように
  **サフィックスが自動で付きます**。読むときは **`xe_slow_queries*.xel` とワイルドカード**を使います。
- **ディスク使用量の上限は `max_file_size × max_rollover_files`** で決まります。
  上の例なら最大 250 MB。**この掛け算を必ず暗算してから本番に置くこと。**
- **フォルダは事前に作成**し、**SQL Server サービスアカウントに書き込み権限**が必要です。
  権限が無いと `CREATE EVENT SESSION` は成功し、**`START` で失敗**します(分かりにくいので注意)。

> **Linux / コンテナー**では `N'/var/opt/mssql/log/xe_slow_queries.xel'` のようなパスを使います。
> **Azure SQL Database** では `CREATE EVENT SESSION ... ON DATABASE` を使い、
> `event_file` の出力先は **Azure Blob Storage の URL** になります
> (カタログビューも `sys.database_event_session_*`)。Azure SQL Managed Instance は `ON SERVER` が使えます。

### 3-3. histogram — 「まず量を測る」ための道具

「本番に入れる前に、そのイベントが1分間に何回起きるのか」を知りたいときに使います。
中身を保持しないので極めて軽量です。

```sql
-- どのエラー番号が何回発生しているかを数えるだけ
ADD TARGET package0.histogram
(
    SET filtering_event_name = N'sqlserver.error_reported',
        source               = N'error_number',
        source_type          = 0        -- 0 = イベントのデータ列 / 1 = アクション(既定)
)
```

- `source_type = 0` は **イベントのデータ列**、`1` は **アクション**を集計対象にします。
  **既定が `1`(アクション)** なので、データ列で集計したいときは **明示が必須**です。ここはよく間違えます。
- 1セッションに `histogram` を複数付ける場合、`filtering_event_name` でどのイベントを数えるか指定します。

### 3-4. event_counter — 件数だけ

```sql
ADD TARGET package0.event_counter
```

オプションなし。**「そのセッションのイベントが合計何件発火したか」だけ**を数えます。
`histogram` よりさらに軽く、**本番導入前のコスト見積もり**に最適です。

### 3-5. pair_matching — 「片割れが来ていない」ものを探す

開始イベントと終了イベントをペアにし、**ペアが揃ったものを捨て、揃っていないものだけを残します**。
「取得したまま解放されていないロック」「開始したのに終わっていないトランザクション」を炙り出す用途です。

```sql
ADD TARGET package0.pair_matching
(
    SET begin_event            = N'sqlserver.lock_acquired',
        begin_matching_columns = N'transaction_id, resource_0, resource_1, resource_2, database_id, resource_type, mode',
        end_event              = N'sqlserver.lock_released',
        end_matching_columns   = N'transaction_id, resource_0, resource_1, resource_2, database_id, resource_type, mode',
        respond_to_memory_pressure = 1
)
```

> ⚠️ `lock_acquired` / `lock_released` は **極めて高頻度**のイベントです。
> `pair_matching` を使うときは **必ず述語で対象を1オブジェクト・1セッションまで絞ってください**。
> 絞らずに本番で流すと、それ自体が障害になります。

## 4. T-SQL での作り方 —— `CREATE EVENT SESSION`

### 4-1. 基本形

```sql
CREATE EVENT SESSION [セッション名] ON SERVER
ADD EVENT パッケージ.イベント名
(
    SET      オプション = 値              -- 省略可(イベント固有の設定)
    ACTION ( パッケージ.アクション名, ... ) -- 省略可
    WHERE  ( 述語 )                       -- 省略可(だが本番では必須)
),
ADD EVENT ...                             -- イベントは複数書ける(カンマ区切り)
ADD TARGET パッケージ.ターゲット名 ( SET オプション = 値, ... )
WITH ( セッションオプション );
```

### 4-2. `WITH` に書けるセッションオプション

| オプション | 既定 | 意味と指針 |
|---|---|---|
| `MAX_MEMORY` | 4 MB | イベントバッファの合計サイズ。足りないとイベントが落ちる |
| `EVENT_RETENTION_MODE` | `ALLOW_SINGLE_EVENT_LOSS` | バッファが溢れたときの挙動(下記) |
| `MAX_DISPATCH_LATENCY` | **30 SECONDS** | バッファからターゲットへ送り出すまでの最大待ち時間 |
| `MAX_EVENT_SIZE` | 0 KB | 1イベントの最大サイズ。0 = 制限なし(`MAX_MEMORY` に従う) |
| `MEMORY_PARTITION_MODE` | `NONE` | `NONE` / `PER_NODE` / `PER_CPU`。高負荷時は分割するとバッファ競合が減る |
| `TRACK_CAUSALITY` | `OFF` | `ON` にすると全イベントに `attach_activity_id` が付き、因果関係を追える |
| `STARTUP_STATE` | `OFF` | `ON` にすると **SQL Server サービス起動時に自動開始** |

**`EVENT_RETENTION_MODE` の3択:**

| 値 | 挙動 | 使いどころ |
|---|---|---|
| `ALLOW_SINGLE_EVENT_LOSS`(既定) | バッファが満杯なら **1イベントずつ捨てる** | **通常はこれ** |
| `ALLOW_MULTIPLE_EVENT_LOSS` | バッファ **1枚分をまとめて捨てる** | 超高頻度イベントで、取りこぼしを許容できるとき |
| `NO_EVENT_LOSS` | **1件も落とさない。落とさないためにワーカースレッドを待たせる** | **本番では原則禁止**。Profiler と同じ害が出る |

> ⚠️ **`MAX_DISPATCH_LATENCY` の既定は 30 秒です。**
> 「セッションを開始してクエリを流したのに、`ring_buffer` が空っぽ」の
> **最大の原因がこれ**です。まだバッファの中にいるだけで、失敗していません。
> **学習中は `MAX_DISPATCH_LATENCY = 5 SECONDS`** にしておくと結果がすぐ見えます。
> なお `0 SECONDS` は「即座に」ではなく **`INFINITE`(バッファが満杯になるまで送らない)** の意味です。逆効果なので注意。

### 4-3. 実際に作ってみる(遅いクエリの捕捉)

```sql
-- 既に同名があれば消してから作る(何度でも実行できるようにする定石)
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'xe_slow_queries')
    DROP EVENT SESSION [xe_slow_queries] ON SERVER;
GO

CREATE EVENT SESSION [xe_slow_queries] ON SERVER

-- (1) アドホックな SQL 文(バッチ内の1文ごと)
ADD EVENT sqlserver.sql_statement_completed
(
    ACTION
    (
        sqlserver.session_id,
        sqlserver.database_name,
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.username,
        sqlserver.sql_text
    )
    -- 安い条件(イベント自身の列)を先に、述語ソースを後に
    WHERE ( [duration] > 100000                                  -- 100,000 マイクロ秒 = 100 ミリ秒
            AND [sqlserver].[database_name] = N'SalesLearning'
            AND [sqlserver].[is_system] = 0 )                    -- システム内部の実行を除外
),

-- (2) アプリからのストアドプロシージャ呼び出し(実務ではこちらが主役)
ADD EVENT sqlserver.rpc_completed
(
    ACTION
    (
        sqlserver.session_id,
        sqlserver.database_name,
        sqlserver.client_app_name,
        sqlserver.username,
        sqlserver.sql_text
    )
    WHERE ( [duration] > 100000
            AND [sqlserver].[database_name] = N'SalesLearning'
            AND [sqlserver].[is_system] = 0 )
)

ADD TARGET package0.ring_buffer ( SET max_memory = 4096, max_events_limit = 1000 )

WITH
(
    MAX_MEMORY            = 8 MB,
    EVENT_RETENTION_MODE  = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY  = 5 SECONDS,
    MEMORY_PARTITION_MODE = NONE,
    TRACK_CAUSALITY       = OFF,
    STARTUP_STATE         = OFF
);
GO
```

> ⚠️ **`duration` の単位はイベントによって違います。ここは事故が非常に多い箇所です。**
>
> | イベント | `duration` の単位 |
> |---|---|
> | `sql_statement_completed` / `sql_batch_completed` / `rpc_completed` / `module_end` | **マイクロ秒** |
> | `blocked_process_report` | **マイクロ秒** |
> | `wait_info` / `wait_info_external` | **ミリ秒** |
>
> 迷ったら **必ず `sys.dm_xe_object_columns` の `description` を確認**してください(第10節)。
> 「1秒以上を捕まえるつもりが 1 ミリ秒以上で全部引っかかった」は典型的な失敗です。

### 4-4. 開始・停止・削除

```sql
-- 開始
ALTER EVENT SESSION [xe_slow_queries] ON SERVER STATE = START;

-- 停止(★ring_buffer の中身はここで消えます。読んでから止めること)
ALTER EVENT SESSION [xe_slow_queries] ON SERVER STATE = STOP;

-- 定義ごと削除
DROP EVENT SESSION [xe_slow_queries] ON SERVER;
```

`ALTER` では中身の変更もできます(**実行中でも可能**)。

```sql
-- イベントを外す
ALTER EVENT SESSION [xe_slow_queries] ON SERVER DROP EVENT sqlserver.rpc_completed;

-- イベントを足す
ALTER EVENT SESSION [xe_slow_queries] ON SERVER
ADD EVENT sqlserver.sql_batch_completed
( ACTION (sqlserver.sql_text) WHERE ([duration] > 1000000) );

-- ターゲットを足す/外す
ALTER EVENT SESSION [xe_slow_queries] ON SERVER
ADD TARGET package0.event_counter;

ALTER EVENT SESSION [xe_slow_queries] ON SERVER
DROP TARGET package0.event_counter;
```

> ⚠️ **述語(`WHERE`)だけを変えることはできません。**
> `ALTER ... DROP EVENT` してから `ADD EVENT` で入れ直します。
> また、**ターゲットを付け外しすると、そのターゲットに溜まっていたデータは失われます**。

### 4-5. 定義と状態を確認する

```sql
-- 定義されているセッション(停止中も含む)
SELECT es.name                       AS セッション名,
       es.startup_state              AS 起動時に自動開始,
       CASE WHEN dm.address IS NULL THEN N'停止中' ELSE N'実行中' END AS 状態
FROM   sys.server_event_sessions AS es
LEFT   JOIN sys.dm_xe_sessions   AS dm ON dm.name = es.name
ORDER  BY es.name;

-- そのセッションに含まれるイベント / アクション / 述語
SELECT e.name                        AS イベント,
       e.predicate                   AS 述語,
       a.name                        AS アクション
FROM   sys.server_event_session_events  AS e
JOIN   sys.server_event_sessions        AS s ON s.event_session_id = e.event_session_id
LEFT   JOIN sys.server_event_session_actions AS a
       ON  a.event_session_id = e.event_session_id
       AND a.event_id         = e.event_id
WHERE  s.name = N'xe_slow_queries';

-- ターゲットの設定値
SELECT t.name AS ターゲット, f.name AS 設定名, f.value AS 設定値
FROM   sys.server_event_session_targets AS t
JOIN   sys.server_event_sessions        AS s ON s.event_session_id = t.event_session_id
LEFT   JOIN sys.server_event_session_fields AS f
       ON  f.event_session_id = t.event_session_id
       AND f.object_id        = t.target_id
WHERE  s.name = N'xe_slow_queries';
```

**イベントが落ちていないかも「計測」します。**

```sql
SELECT name                       AS セッション名,
       dropped_event_count        AS 落ちたイベント数,      -- ★0 であってほしい
       dropped_buffer_count       AS 落ちたバッファ数,
       largest_event_dropped_size AS 落ちた最大サイズ,
       blocked_event_fire_time    AS 発火がブロックされた時間,
       total_regular_buffers,
       regular_buffer_size
FROM   sys.dm_xe_sessions
ORDER  BY name;
```

> **判断基準**: `dropped_event_count` が増え続けるなら、
> ① 述語が緩すぎてイベント量が多すぎる、② `MAX_MEMORY` が小さい、③ ディスクが遅い、のいずれかです。
> **まず疑うのは ①** です。`MAX_MEMORY` を増やす前に、フィルタを見直してください。
> `largest_event_dropped_size` が大きいなら、1イベントがバッファに収まっていないので `MAX_EVENT_SIZE` を検討します。

## 5. 【最大の関門】結果の読み方 —— ring_buffer の XML を表にする

拡張イベントで挫折する人の 9 割はここです。**ターゲットのデータは XML で返ってきます。**
これを `nodes()` と `value()` で表に展開する定型パターンを、必ず手に馴染ませてください。

### 5-1. まずは生の XML を眺める

```sql
SELECT CAST(t.target_data AS XML) AS target_data
FROM   sys.dm_xe_sessions        AS s
JOIN   sys.dm_xe_session_targets AS t ON t.event_session_address = s.address
WHERE  s.name        = N'xe_slow_queries'
  AND  t.target_name = N'ring_buffer';
```

返ってくる XML はこういう構造です(これを頭に入れておくと `value()` のパスが自分で書けます)。

```xml
<RingBufferTarget truncated="0" eventCount="3" droppedCount="0" memoryUsed="4808">
  <event name="sql_statement_completed" package="sqlserver" timestamp="2026-07-26T04:12:33.481Z">
    <data name="duration">   <type name="uint64" package="package0"/><value>1234567</value></data>
    <data name="cpu_time">   <type name="uint64" package="package0"/><value>1200000</value></data>
    <data name="logical_reads"><type name="uint64" package="package0"/><value>85231</value></data>
    <data name="row_count">  <type name="uint64" package="package0"/><value>1</value></data>
    <data name="statement">  <type name="unicode_string" package="package0"/><value>SELECT SUM(Amount) ...</value></data>
    <action name="session_id" package="sqlserver"><type .../><value>58</value></action>
    <action name="sql_text"   package="sqlserver"><type .../><value>SELECT SUM(Amount) ...</value></action>
  </event>
  <event name="rpc_completed" ...> ... </event>
</RingBufferTarget>
```

**規則はたった3つです。**

1. イベント1件 = `<event>` 要素1つ → `nodes('/RingBufferTarget/event')` で1行に展開する。
2. **イベントの標準列は `data`**、**追加で採った情報は `action`**。タグ名が違うだけで書き方は同じ。
3. 値の取り出しは `(data[@name="列名"]/value)[1]` / `(action[@name="名前"]/value)[1]`。
   **`[1]` を付けないと `value()` はエラー**になります(単一値であることを保証する必要があるため)。

### 5-2. 表形式に変換する(この章の中核クエリ)

```sql
WITH RB AS
(
    SELECT CAST(t.target_data AS XML) AS TargetData
    FROM   sys.dm_xe_sessions        AS s
    JOIN   sys.dm_xe_session_targets AS t ON t.event_session_address = s.address
    WHERE  s.name        = N'xe_slow_queries'
      AND  t.target_name = N'ring_buffer'
)
SELECT
    x.value('@name', 'nvarchar(100)')                                        AS イベント種別,
    -- timestamp は必ず UTC。日本時間にするなら変換する(AT TIME ZONE は SQL Server 2016+)
    x.value('@timestamp', 'datetime2')
        AT TIME ZONE 'UTC' AT TIME ZONE 'Tokyo Standard Time'                AS 発生時刻JST,
    x.value('(data[@name="duration"]/value)[1]', 'bigint') / 1000.0          AS 実行時間ms,
    x.value('(data[@name="cpu_time"]/value)[1]', 'bigint') / 1000.0          AS CPU時間ms,
    x.value('(data[@name="logical_reads"]/value)[1]', 'bigint')              AS 論理読み取り,
    x.value('(data[@name="physical_reads"]/value)[1]', 'bigint')             AS 物理読み取り,
    x.value('(data[@name="writes"]/value)[1]', 'bigint')                     AS 書き込み,
    x.value('(data[@name="row_count"]/value)[1]', 'bigint')                  AS 行数,
    x.value('(action[@name="session_id"]/value)[1]', 'int')                  AS セッションID,
    x.value('(action[@name="database_name"]/value)[1]', 'nvarchar(128)')     AS データベース,
    x.value('(action[@name="client_app_name"]/value)[1]', 'nvarchar(256)')   AS アプリ名,
    x.value('(action[@name="username"]/value)[1]', 'nvarchar(128)')          AS ログイン,
    x.value('(data[@name="statement"]/value)[1]', 'nvarchar(max)')           AS 実行された文,
    x.value('(action[@name="sql_text"]/value)[1]', 'nvarchar(max)')          AS バッチ全文
FROM   RB
CROSS  APPLY RB.TargetData.nodes('/RingBufferTarget/event') AS e(x)
ORDER  BY 実行時間ms DESC;
```

**この形が全パターンの土台**です。以降のデッドロック・ブロッキング・エラーも、
`nodes()` のパスと `value()` の列名を差し替えるだけです。

> ⚠️ **`AT TIME ZONE` は SQL Server 2016 以降**です。2014 以前なら `DATEADD(HOUR, 9, ...)` で代用します
> (ただし夏時間のある地域では正しくありません。日本標準時は夏時間が無いので問題ありません)。

> ⚠️ **`statement` と `sql_text` は別物です。**
> - `statement`(データ列) = **そのイベントが指す1文だけ**
> - `sqlserver.sql_text`(アクション) = **そのバッチ全体のテキスト**
>
> 「500行のストアドのどこが遅いか」を知りたいなら `statement`、
> 「そもそも誰がどんなバッチを投げたか」なら `sql_text` を見ます。

### 5-3. 「集計してから見る」

生ログを目で追うのは非効率です。**まず集計**しましょう。

```sql
WITH RB AS
(
    SELECT CAST(t.target_data AS XML) AS TargetData
    FROM   sys.dm_xe_sessions        AS s
    JOIN   sys.dm_xe_session_targets AS t ON t.event_session_address = s.address
    WHERE  s.name = N'xe_slow_queries' AND t.target_name = N'ring_buffer'
),
E AS
(
    SELECT x.value('(data[@name="statement"]/value)[1]', 'nvarchar(max)')  AS 文,
           x.value('(data[@name="duration"]/value)[1]', 'bigint')          AS 時間us,
           x.value('(data[@name="logical_reads"]/value)[1]', 'bigint')     AS 論理読み取り
    FROM   RB CROSS APPLY RB.TargetData.nodes('/RingBufferTarget/event') AS e(x)
)
SELECT LEFT(文, 120)                        AS 文の先頭,
       COUNT(*)                             AS 実行回数,
       SUM(時間us) / 1000.0                 AS 合計ms,
       AVG(時間us) / 1000.0                 AS 平均ms,
       MAX(時間us) / 1000.0                 AS 最大ms,
       SUM(論理読み取り)                     AS 合計論理読み取り
FROM   E
GROUP  BY LEFT(文, 120)
ORDER  BY 合計ms DESC;
```

> **判断基準**: `平均ms` が小さいのに `合計ms` が大きいものは
> **「1回は速いが呼ばれすぎている」**クエリです。チューニング対象はしばしばこちらで、
> 「たまに遅い1本」より改善効果が大きいことがあります([24章](24_query_store.md) の考え方と同じです)。

## 6. 【最大の関門・その2】event_file の読み方

`event_file` は `sys.fn_xe_file_target_read_file` で読みます。**セッションが停止していても読めます**
(ファイルに残っているため)。ここが `ring_buffer` との決定的な違いです。

```sql
-- 生のまま(1行 = 1イベント)
SELECT object_name          AS イベント種別,
       CAST(event_data AS XML) AS イベントXML,
       file_name,
       file_offset
FROM   sys.fn_xe_file_target_read_file
       (
           N'C:\XE\xe_slow_queries*.xel',  -- ★ワイルドカード必須(自動サフィックスが付くため)
           NULL,                            -- メタデータファイル: SQL Server 2012 以降は NULL でよい
           NULL,                            -- 読み始めるファイル名(続きから読むとき)
           NULL                             -- 読み始めるオフセット
       );
```

> ⚠️ `event_file` の1行は **`<event>` を根とする XML** です。
> `ring_buffer` のように `<RingBufferTarget>` で包まれていません。
> したがって **`nodes()` のパスが `/event`(または `event`)になります**。ここが混同ポイントです。

```sql
WITH F AS
(
    SELECT CAST(event_data AS XML) AS ED
    FROM   sys.fn_xe_file_target_read_file(N'C:\XE\xe_slow_queries*.xel', NULL, NULL, NULL)
)
SELECT
    x.value('@name', 'nvarchar(100)')                                       AS イベント種別,
    x.value('@timestamp', 'datetime2')
        AT TIME ZONE 'UTC' AT TIME ZONE 'Tokyo Standard Time'               AS 発生時刻JST,
    x.value('(data[@name="duration"]/value)[1]', 'bigint') / 1000.0         AS 実行時間ms,
    x.value('(data[@name="logical_reads"]/value)[1]', 'bigint')             AS 論理読み取り,
    x.value('(action[@name="session_id"]/value)[1]', 'int')                 AS セッションID,
    x.value('(action[@name="client_app_name"]/value)[1]', 'nvarchar(256)')  AS アプリ名,
    x.value('(data[@name="statement"]/value)[1]', 'nvarchar(max)')          AS 実行された文
FROM   F
CROSS  APPLY F.ED.nodes('/event') AS e(x)      -- ★ここが ring_buffer と違う
ORDER  BY 実行時間ms DESC;
```

**読み込み量が多いときのコツ**

- `.xel` が数十 GB あると、上のクエリだけで長時間かかります。
  **まず件数だけ数える** → **`file_name` / `file_offset` で範囲を絞る** → 本命のクエリ、の順に進めます。
- 恒久的に分析するなら、いったん **テーブルに落としてからインデックスを張る**のが定石です。

```sql
-- 分析用に一時テーブルへ取り込む(取り込んでから何度でも集計できる)
DROP TABLE IF EXISTS #XE;

SELECT CAST(event_data AS XML) AS ED
INTO   #XE
FROM   sys.fn_xe_file_target_read_file(N'C:\XE\xe_slow_queries*.xel', NULL, NULL, NULL);

SELECT COUNT(*) AS 取り込み件数 FROM #XE;
```

> ⚠️ **`.xel` ファイルの後始末**: `DROP EVENT SESSION` してもファイルは**残ります**。
> 不要になったら **OS 側で削除**してください(SSMS からは消せません)。
> セッションが動いている間はファイルがロックされているので、**先に `STOP` してから**削除します。

## 7. 実用例(a) 遅いクエリの捕捉 —— 実際に流してみる

第4節で作った `xe_slow_queries` を実際に動かします。

```sql
-- 1. 開始
ALTER EVENT SESSION [xe_slow_queries] ON SERVER STATE = START;

-- 2. わざと遅いクエリを流す(dbo.OrdersBig は100万行。インデックスが無いので全件スキャンになる)
SELECT SUM(Amount) AS 合計 FROM dbo.OrdersBig WHERE Status = N'保留';
SELECT SUM(Amount) AS 合計 FROM dbo.OrdersBig WHERE YEAR(OrderDate) = 2020;   -- SARGable でない書き方

-- 3. MAX_DISPATCH_LATENCY(5秒)を待ってから、第5節の展開クエリで読む
WAITFOR DELAY '00:00:06';
```

そのうえで第 5-2 節のクエリを実行すると、2本のクエリが `duration` 降順で並びます。

- `sql_statement_completed` は **バッチ内の1文ごと**に発火します。
  1バッチ全体の時間が欲しいなら `sql_batch_completed` を使います。
- アプリケーション(ADO.NET / JDBC など)からの呼び出しは、
  ほとんどが **`rpc_completed`** として現れます。`sql_statement_completed` だけを仕掛けて
  「何も採れない」と悩むのは非常によくある失敗です。**両方入れておくのが安全**です。

> **実務のしきい値の決め方**: いきなり `duration > 0` にしてはいけません。
> ① まず `event_counter` か `histogram` で「1分間に何件出るか」を測る
> → ② 1分あたり数百件に収まるしきい値まで `duration` を上げる、が正しい手順です。

## 8. 実用例(b) デッドロックの捕捉 —— `xml_deadlock_report`

[19章](19_transactions_isolation.md) では「デッドロックとは何か」「なぜ起きるか」を扱いました。
ここでは **「起きた瞬間の証拠を確実に残し、読み解く」** ことに集中します。

### 8-1. セッションを作る

```sql
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'xe_deadlocks')
    DROP EVENT SESSION [xe_deadlocks] ON SERVER;
GO

CREATE EVENT SESSION [xe_deadlocks] ON SERVER
ADD EVENT sqlserver.xml_deadlock_report
ADD TARGET package0.ring_buffer ( SET max_memory = 4096, max_events_limit = 100 )
WITH
(
    MAX_MEMORY           = 4 MB,
    EVENT_RETENTION_MODE = ALLOW_SINGLE_EVENT_LOSS,
    MAX_DISPATCH_LATENCY = 5 SECONDS,
    STARTUP_STATE        = OFF        -- 本番で常設するなら ON にする
);
GO

ALTER EVENT SESSION [xe_deadlocks] ON SERVER STATE = START;
```

- **アクションは付けていません。** `xml_deadlock_report` が返す XML には、
  関与した全セッションの SPID・実行中の SQL・分離レベル・待っていたリソースが **すべて入っている**からです。
- **述語も書いていません。** `xml_deadlock_report` は
  **データベース名でフィルタできる列を持ちません**(デッドロックは複数DBにまたがり得るため)。
  代わりに **発生頻度が極めて低い**イベントなので、フィルタ無しでも実害はほぼありません。
- 本番の常設監視では **`STARTUP_STATE = ON` + `event_file`** の組み合わせが定番です。

### 8-2. デッドロックを実際に起こす(2セッション)

[19章](19_transactions_isolation.md) 11-2節と同じ手順です。SSMS のクエリウィンドウを **2つ** 開きます。

```sql
-- 【セッションA】手順1: Employees をロック
BEGIN TRAN;
UPDATE dbo.Employees SET Salary = Salary WHERE EmployeeId = 3;
```

```sql
-- 【セッションB】手順2: Products をロック(A と獲得順序が逆)
BEGIN TRAN;
UPDATE dbo.Products SET UnitPrice = UnitPrice WHERE ProductId = 2;
```

```sql
-- 【セッションA】手順3: 次に Products が欲しい → B に待たされる
UPDATE dbo.Products SET UnitPrice = UnitPrice WHERE ProductId = 2;
```

```sql
-- 【セッションB】手順4: 次に Employees が欲しい → デッドロック成立(数秒後にエラー 1205)
UPDATE dbo.Employees SET Salary = Salary WHERE EmployeeId = 3;
```

```sql
-- 【セッションA】【セッションB】手順5: 両方で必ず後片付け
IF @@TRANCOUNT > 0 ROLLBACK;
SELECT @@SPID AS セッションID, @@TRANCOUNT AS 深さ;   -- 0 であること
```

### 8-3. デッドロックグラフを取り出す

```sql
WITH RB AS
(
    SELECT CAST(t.target_data AS XML) AS TargetData
    FROM   sys.dm_xe_sessions        AS s
    JOIN   sys.dm_xe_session_targets AS t ON t.event_session_address = s.address
    WHERE  s.name = N'xe_deadlocks' AND t.target_name = N'ring_buffer'
)
SELECT
    x.value('@timestamp', 'datetime2')
        AT TIME ZONE 'UTC' AT TIME ZONE 'Tokyo Standard Time'   AS 発生時刻JST,
    x.query('(data[@name="xml_deadlock_report"]/value/deadlock)[1]') AS デッドロックグラフ
FROM   RB
CROSS  APPLY RB.TargetData.nodes('/RingBufferTarget/event[@name="xml_deadlock_report"]') AS e(x)
ORDER  BY 発生時刻JST DESC;
```

> ⚠️ **列名は `xml_deadlock_report`(イベント名と同じ)** です。`xml_report` ではありません
> (`xml_report` は古い `lock_deadlock*` 系イベントの列名です)。
> `x.query(...)` の結果が空なら、**`x.query('.')` で `<event>` を丸ごと表示して、
> 実際の `data name=` を目で確認**するのが確実な切り分け方です。

**結果セルの XML をクリックすると新しいタブで開きます。**
それを **`.xdl` という拡張子で保存して SSMS で開き直す**と、
**デッドロックグラフの図**(2つのプロセスが楕円で、リソースが四角で表示される)として見られます。

### 8-4. デッドロックグラフの読み方

`<deadlock>` の中身はこういう構造です。

```xml
<deadlock>
  <victim-list>
    <victimProcess id="process1a2b3c"/>          <!-- ← 犠牲者。この process id を覚える -->
  </victim-list>
  <process-list>
    <process id="process1a2b3c" spid="58" status="suspended"
             waitresource="KEY: 9:72057594045595648 (61a06abd401c)"
             lockMode="X" isolationlevel="read committed (2)"
             transactionname="user_transaction" lasttranstarted="..."
             clientapp="Microsoft SQL Server Management Studio - Query"
             hostname="..." loginname="...">
      <executionStack>
        <frame procname="adhoc" line="1" ...>UPDATE dbo.Products ...</frame>
      </executionStack>
      <inputbuf>UPDATE dbo.Products SET UnitPrice = UnitPrice WHERE ProductId = 2;</inputbuf>
    </process>
    <process id="process4d5e6f" spid="59" ...> ... </process>
  </process-list>
  <resource-list>
    <keylock hobtid="..." dbid="9" objectname="SalesLearning.dbo.Products"
             indexname="PK_Products" id="lock123" mode="X" associatedObjectId="...">
      <owner-list> <owner id="process4d5e6f" mode="X"/> </owner-list>
      <waiter-list><waiter id="process1a2b3c" mode="X" requestType="wait"/></waiter-list>
    </keylock>
    <keylock ... objectname="SalesLearning.dbo.Employees" indexname="PK_Employees" ...>
      <owner-list> <owner id="process1a2b3c" mode="X"/> </owner-list>
      <waiter-list><waiter id="process4d5e6f" mode="X" requestType="wait"/></waiter-list>
    </keylock>
  </resource-list>
</deadlock>
```

**読む順序は次の4ステップで固定です。**

| 手順 | 見る場所 | 分かること |
|---|---|---|
| **1** | `<victim-list>` の `victimProcess/@id` | **どちらが殺されたか**。アプリのリトライ対象はこちら |
| **2** | `<resource-list>` の `objectname` / `indexname` | **どのテーブルの、どのインデックスで**衝突したか。**対策の主戦場** |
| **3** | 各 `<process>` の `<inputbuf>` と `<executionStack>` | **どの SQL が**ロックを取り合ったか |
| **4** | `owner-list` と `waiter-list` の対応 | **獲得順序**。「A は X を持って Y を待ち、B は Y を持って X を待つ」が復元できる |

**表として抜き出すクエリ**(手作業で XML を目で追うのは非効率です)。

```sql
-- 直近のデッドロックグラフを変数に取り出す
DECLARE @dl XML;

SELECT TOP (1) @dl = x.query('(data[@name="xml_deadlock_report"]/value/deadlock)[1]')
FROM  (
        SELECT CAST(t.target_data AS XML) AS TargetData
        FROM   sys.dm_xe_sessions        AS s
        JOIN   sys.dm_xe_session_targets AS t ON t.event_session_address = s.address
        WHERE  s.name = N'xe_deadlocks' AND t.target_name = N'ring_buffer'
      ) AS RB
CROSS APPLY RB.TargetData.nodes('/RingBufferTarget/event[@name="xml_deadlock_report"]') AS e(x)
ORDER BY x.value('@timestamp', 'datetime2') DESC;

-- ① 関与したプロセス一覧(犠牲者に印を付ける)
SELECT
    CASE WHEN p.value('@id', 'nvarchar(50)')
              = @dl.value('(/deadlock/victim-list/victimProcess/@id)[1]', 'nvarchar(50)')
         THEN N'★犠牲者' ELSE N'生存' END                            AS 判定,
    p.value('@spid', 'int')                                           AS SPID,
    p.value('@lockMode', 'nvarchar(20)')                              AS 要求ロック,
    p.value('@isolationlevel', 'nvarchar(60)')                        AS 分離レベル,
    p.value('@waitresource', 'nvarchar(200)')                         AS 待機リソース,
    p.value('@clientapp', 'nvarchar(200)')                            AS アプリ,
    p.value('@hostname', 'nvarchar(128)')                             AS ホスト,
    p.value('@loginname', 'nvarchar(128)')                            AS ログイン,
    LTRIM(RTRIM(p.value('(inputbuf)[1]', 'nvarchar(max)')))           AS 実行していたSQL
FROM   @dl.nodes('/deadlock/process-list/process') AS t(p);

-- ② 衝突したリソース(対策を考える主戦場)
SELECT
    r.value('local-name(.)', 'nvarchar(50)')                          AS リソース種別,  -- keylock / pagelock / objectlock …
    r.value('@objectname', 'nvarchar(300)')                           AS オブジェクト,
    r.value('@indexname', 'nvarchar(300)')                            AS インデックス,
    r.value('(owner-list/owner/@id)[1]', 'nvarchar(50)')              AS 保持しているプロセス,
    r.value('(owner-list/owner/@mode)[1]', 'nvarchar(20)')            AS 保持モード,
    r.value('(waiter-list/waiter/@id)[1]', 'nvarchar(50)')            AS 待っているプロセス,
    r.value('(waiter-list/waiter/@mode)[1]', 'nvarchar(20)')          AS 要求モード
FROM   @dl.nodes('/deadlock/resource-list/*') AS t(r);
```

**この2つの結果から何を判断するか:**

- **`indexname` が同じ非クラスタ化インデックスばかり** → そのインデックスの更新順序を統一する、
  または **不要なインデックスを削除**する。
- **`objectname` が毎回異なる2表の組み合わせ** → **アクセス順序の不統一**([19章](19_transactions_isolation.md) の本丸)。
- **`waitresource` が `RID:` で始まる** → ヒープ(クラスタ化インデックスが無い表)。
  **クラスタ化インデックスを付けるだけで解消**することがあります。
- **`isolationlevel` が `serializable` や `repeatable read`** → 分離レベルの上げすぎ。
- **`inputbuf` が `SELECT`** → 読み取りが書き込みとデッドロックしている。
  **RCSI の検討**が最も効きます([19章](19_transactions_isolation.md) 8-4節)。

### 8-5. 既定の `system_health` セッションでも取れる

実は **何も仕掛けていなくてもデッドロックは記録されています**。
SQL Server は既定で **`system_health`** という拡張イベントセッションを起動しており、
そこに `xml_deadlock_report` が含まれているからです。

```sql
-- 既定で動いているセッションを確認する
SELECT name FROM sys.dm_xe_sessions ORDER BY name;
-- → system_health / AlwaysOn_health / telemetry_xevents(2016+)/ hkenginexesession など

-- system_health のリングバッファから直近のデッドロックを取り出す
WITH RB AS
(
    SELECT CAST(t.target_data AS XML) AS TargetData
    FROM   sys.dm_xe_sessions        AS s
    JOIN   sys.dm_xe_session_targets AS t ON t.event_session_address = s.address
    WHERE  s.name = N'system_health' AND t.target_name = N'ring_buffer'
)
SELECT x.value('@timestamp', 'datetime2')
           AT TIME ZONE 'UTC' AT TIME ZONE 'Tokyo Standard Time'  AS 発生時刻JST,
       x.query('(data/value/deadlock)[1]')                        AS デッドロックグラフ
FROM   RB
CROSS  APPLY RB.TargetData.nodes('/RingBufferTarget/event[@name="xml_deadlock_report"]') AS e(x)
ORDER  BY 発生時刻JST DESC;
```

`system_health` は **`ring_buffer` と `event_file` の2つのターゲット**を持っています。
`ring_buffer` は容量が小さくすぐ上書きされるので、**過去にさかのぼるなら `event_file`** を読みます。

```sql
-- system_health の event_file から読む(ファイルパスは既定の LOG フォルダー)
SELECT CAST(event_data AS XML) AS ED
INTO   #SH
FROM   sys.fn_xe_file_target_read_file(N'system_health*.xel', NULL, NULL, NULL);

SELECT x.value('@name', 'nvarchar(100)')                         AS イベント,
       x.value('@timestamp', 'datetime2')
           AT TIME ZONE 'UTC' AT TIME ZONE 'Tokyo Standard Time' AS 発生時刻JST,
       x.query('(data[@name="xml_deadlock_report"]/value/deadlock)[1]') AS グラフ
FROM   #SH CROSS APPLY ED.nodes('/event') AS e(x)
WHERE  x.value('@name', 'nvarchar(100)') = N'xml_deadlock_report'
ORDER  BY 発生時刻JST DESC;

DROP TABLE IF EXISTS #SH;
```

> **相対パス `N'system_health*.xel'` は SQL Server の既定の LOG フォルダーからの相対**として解決されます。
> フルパスが知りたいときは次で確認できます。
> ```sql
> SELECT SERVERPROPERTY('ErrorLogFileName') AS エラーログのパス;
> ```

**それでも自前のセッションを作る理由**は次の3つです。

1. `system_health` の `ring_buffer` は **すぐに上書き**され、`event_file` も4ファイル×5MB程度で **数日しか残らない**。
2. `system_health` は **他のイベントも大量に記録**しており、デッドロックだけを長期保存するには向かない。
3. 自前なら **保持期間・ファイルサイズを自分で設計できる**。

## 9. 実用例(c) ブロッキングの捕捉 —— `blocked_process_report`

ブロッキングは **エラーにならず、ただ待つだけ**なので、[19章](19_transactions_isolation.md) のように
「起きている最中に DMV を見る」以外に、後から追う手段が要ります。それが `blocked_process_report` です。

### 9-1. まずサーバー設定を変える(★戻す手順とセットで)

`blocked_process_report` は **`blocked process threshold (s)` が `0`(既定)のままでは一切発火しません**。
ここが最大のつまずきポイントです。

```sql
-- ★現在値を必ず控えてから変更する
EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;

SELECT name, value, value_in_use, description
FROM   sys.configurations
WHERE  name = 'blocked process threshold (s)';
-- → value_in_use が 0 なら「無効」。この値をメモしておく

-- 5秒以上ブロックされたら報告させる(学習用。本番は 15〜30 秒が目安)
EXEC sp_configure 'blocked process threshold (s)', 5;
RECONFIGURE;
```

> ⚠️ **これはインスタンス全体に効くサーバー設定**です。**再起動は不要**ですが、
> **必ず元に戻してください**(手順は 9-5 節)。
> 小さすぎる値(1〜2秒)は、ブロックされている間 **繰り返し**レポートを生成するため、
> それ自体が負荷になります。**本番では 15〜30 秒**から始めるのが定石です。

### 9-2. セッションを作る

```sql
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'xe_blocked')
    DROP EVENT SESSION [xe_blocked] ON SERVER;
GO

CREATE EVENT SESSION [xe_blocked] ON SERVER
ADD EVENT sqlserver.blocked_process_report
(
    ACTION (sqlserver.database_name, sqlserver.client_app_name)
    WHERE  ( [sqlserver].[database_name] = N'SalesLearning' )
)
ADD TARGET package0.ring_buffer ( SET max_memory = 4096, max_events_limit = 200 )
WITH ( MAX_DISPATCH_LATENCY = 5 SECONDS, STARTUP_STATE = OFF );
GO

ALTER EVENT SESSION [xe_blocked] ON SERVER STATE = START;
```

### 9-3. ブロッキングを起こす —— `sample-db/05_workload.sql`

負荷生成スクリプト `sample-db/05_workload.sql` の **セクションC(ブロッカー)** と
**セクションD(ブロックされる側)** を、**別々のクエリウィンドウ**で流します。

```sql
-- 【セッションA】手順1: 05_workload.sql のセクションC(30秒間ロックを保持して自動 ROLLBACK)
BEGIN TRANSACTION;

UPDATE dbo.WorkloadTest
SET    Val = Val + 1000
WHERE  Id BETWEEN 1 AND 10;

WAITFOR DELAY '00:00:30';

ROLLBACK TRANSACTION;
```

```sql
-- 【セッションB】手順2: セクションD(セッションAの実行中に流す → 待たされる)
SELECT Id, Val, UpdatedAt
FROM   dbo.WorkloadTest
WHERE  Id BETWEEN 1 AND 10;
-- → 5秒経過した時点で blocked_process_report が発火する
```

- **`blocked process threshold` に達するまで発火しません。** セクションDが5秒以上待つ必要があります。
- セクションCは30秒で自動的に `ROLLBACK` するので、放置しても安全です。

### 9-4. レポートを読む

```sql
WITH RB AS
(
    SELECT CAST(t.target_data AS XML) AS TargetData
    FROM   sys.dm_xe_sessions        AS s
    JOIN   sys.dm_xe_session_targets AS t ON t.event_session_address = s.address
    WHERE  s.name = N'xe_blocked' AND t.target_name = N'ring_buffer'
),
E AS
(
    SELECT x.value('@timestamp', 'datetime2')
               AT TIME ZONE 'UTC' AT TIME ZONE 'Tokyo Standard Time'          AS 発生時刻JST,
           x.value('(data[@name="duration"]/value)[1]', 'bigint') / 1000000.0 AS ブロック秒数,
           DB_NAME(x.value('(data[@name="database_id"]/value)[1]', 'int'))    AS データベース,
           x.value('(data[@name="lock_mode"]/value)[1]', 'nvarchar(30)')      AS ロックモード,
           x.query('(data[@name="blocked_process"]/value/blocked-process-report)[1]') AS レポート
    FROM   RB CROSS APPLY RB.TargetData.nodes('/RingBufferTarget/event') AS e(x)
)
SELECT 発生時刻JST,
       ブロック秒数,
       データベース,
       ロックモード,
       -- 待たされている側
       レポート.value('(/blocked-process-report/blocked-process/process/@spid)[1]', 'int')            AS 待機SPID,
       LTRIM(RTRIM(レポート.value('(/blocked-process-report/blocked-process/process/inputbuf)[1]', 'nvarchar(max)')))   AS 待機側SQL,
       レポート.value('(/blocked-process-report/blocked-process/process/@waitresource)[1]', 'nvarchar(200)')            AS 待機リソース,
       レポート.value('(/blocked-process-report/blocked-process/process/@isolationlevel)[1]', 'nvarchar(60)')           AS 待機側分離レベル,
       -- 待たせている側(★真犯人はこちら)
       レポート.value('(/blocked-process-report/blocking-process/process/@spid)[1]', 'int')           AS ブロック元SPID,
       レポート.value('(/blocked-process-report/blocking-process/process/@status)[1]', 'nvarchar(30)') AS ブロック元の状態,
       LTRIM(RTRIM(レポート.value('(/blocked-process-report/blocking-process/process/inputbuf)[1]', 'nvarchar(max)'))) AS ブロック元SQL,
       レポート                                                                                        AS 生レポートXML
FROM   E
ORDER  BY 発生時刻JST DESC;
```

**判断基準 —— `blocking-process` の `status` を必ず見ること:**

| `status` | 意味 | 疑うこと |
|---|---|---|
| `running` / `runnable` | 実際に処理中 | 長いクエリ。インデックス不足を疑う([18章](18_indexes_execution_plans.md)) |
| `suspended` | **こちらも何かを待っている** | 連鎖ブロッキング。さらに上流を追う |
| **`sleeping`** | **何も実行していないのにトランザクションを開いたまま** | **アプリのバグ**。`COMMIT` 漏れ、`IMPLICIT_TRANSACTIONS ON`、トランザクション中のユーザー入力待ち |

> **`status = sleeping` かつ `inputbuf` が空**、というのは実務で最も多いパターンで、
> ほぼ確実に **「アプリがトランザクションを開いたまま放置している」** サインです。
> このときは `sys.dm_exec_sessions.last_request_end_time` と併せて
> 「いつから寝ているのか」を確認します([26 DMVによる調査](26_dmv_investigation.md))。

### 9-5. サーバー設定を必ず戻す

```sql
-- ★ 9-1 で控えた元の値に戻す(既定は 0 = 無効)
EXEC sp_configure 'blocked process threshold (s)', 0;
RECONFIGURE;

-- 戻ったことを確認
SELECT name, value, value_in_use
FROM   sys.configurations
WHERE  name = 'blocked process threshold (s)';
-- → value_in_use = 0 であること

-- 詳細オプション表示も元に戻す
EXEC sp_configure 'show advanced options', 0;
RECONFIGURE;
```

## 10. 実用例(d) エラーの捕捉 —— `error_reported`

「アプリのログには『DBエラー』としか出ていない」という状況で、
**サーバー側から見た本当のエラー内容**を拾うためのイベントです。

```sql
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'xe_errors')
    DROP EVENT SESSION [xe_errors] ON SERVER;
GO

CREATE EVENT SESSION [xe_errors] ON SERVER
ADD EVENT sqlserver.error_reported
(
    ACTION
    (
        sqlserver.session_id,
        sqlserver.database_name,
        sqlserver.client_app_name,
        sqlserver.client_hostname,
        sqlserver.username,
        sqlserver.sql_text
    )
    WHERE ( [severity] >= 11                                       -- 11 未満は情報メッセージ
            AND [sqlserver].[database_name] = N'SalesLearning'
            AND [sqlserver].[is_system] = 0 )
)
ADD TARGET package0.ring_buffer ( SET max_memory = 4096, max_events_limit = 500 )
ADD TARGET package0.histogram
(
    SET filtering_event_name = N'sqlserver.error_reported',
        source               = N'error_number',
        source_type          = 0                                   -- ★データ列なので 0
)
WITH ( MAX_DISPATCH_LATENCY = 5 SECONDS, STARTUP_STATE = OFF );
GO

ALTER EVENT SESSION [xe_errors] ON SERVER STATE = START;
```

わざとエラーを起こしてみます。

```sql
SELECT * FROM dbo.存在しない表;                       -- エラー 208(オブジェクト名が無効)
SELECT 1 / 0 AS ゼロ除算;                              -- エラー 8134
RAISERROR (N'テスト用のエラーです', 16, 1);             -- 重大度 16
INSERT INTO dbo.Departments (DepartmentId, DepartmentName, Location)
VALUES (1, N'重複', N'東京');                          -- エラー 2627(主キー違反)
WAITFOR DELAY '00:00:06';
```

読み出します。

```sql
WITH RB AS
(
    SELECT CAST(t.target_data AS XML) AS TargetData
    FROM   sys.dm_xe_sessions        AS s
    JOIN   sys.dm_xe_session_targets AS t ON t.event_session_address = s.address
    WHERE  s.name = N'xe_errors' AND t.target_name = N'ring_buffer'
)
SELECT x.value('@timestamp', 'datetime2')
           AT TIME ZONE 'UTC' AT TIME ZONE 'Tokyo Standard Time'       AS 発生時刻JST,
       x.value('(data[@name="error_number"]/value)[1]', 'int')         AS エラー番号,
       x.value('(data[@name="severity"]/value)[1]', 'int')             AS 重大度,
       x.value('(data[@name="state"]/value)[1]', 'int')                AS 状態,
       x.value('(data[@name="message"]/value)[1]', 'nvarchar(max)')    AS メッセージ,
       x.value('(action[@name="session_id"]/value)[1]', 'int')         AS セッションID,
       x.value('(action[@name="client_app_name"]/value)[1]', 'nvarchar(256)') AS アプリ,
       x.value('(action[@name="username"]/value)[1]', 'nvarchar(128)') AS ログイン,
       x.value('(action[@name="sql_text"]/value)[1]', 'nvarchar(max)') AS 実行SQL
FROM   RB CROSS APPLY RB.TargetData.nodes('/RingBufferTarget/event') AS e(x)
ORDER  BY 発生時刻JST DESC;
```

**`histogram` ターゲットのほうは「エラー番号ごとの件数」だけ**を返します。

```sql
WITH H AS
(
    SELECT CAST(t.target_data AS XML) AS TargetData
    FROM   sys.dm_xe_sessions        AS s
    JOIN   sys.dm_xe_session_targets AS t ON t.event_session_address = s.address
    WHERE  s.name = N'xe_errors' AND t.target_name = N'histogram'
)
SELECT v.value('(value)[1]', 'int')  AS エラー番号,
       v.value('@count', 'bigint')   AS 件数
FROM   H CROSS APPLY H.TargetData.nodes('/HistogramTarget/Slot') AS s(v)
ORDER  BY 件数 DESC;
```

> ⚠️ **`error_reported` は本番でとにかく数が多いイベント**です。
> ログイン失敗、`SET` オプションの警告、アプリの想定内エラー(重複キーを握りつぶす作り)などが
> 大量に発火します。**`severity` と `error_number` で必ず絞り込んでください。**
>
> 実務で有用な絞り込み例:
> - `[error_number] = 1205` … デッドロックの犠牲者(リトライの実効回数を測る)
> - `[error_number] = 1222` … ロック要求のタイムアウト
> - `[error_number] = 8645 OR [error_number] = 8651` … メモリ許可待ちのタイムアウト
> - `[severity] >= 17` … サーバー側のリソース問題・内部エラーだけに絞る

## 11. 使えるイベント・アクション・ターゲットの探し方

「そんなイベントあるの?」は **カタログを検索して確かめる**のが正解です。推測しないこと。

```sql
-- ① イベントを名前で探す(例: deadlock を含むもの)
SELECT p.name          AS パッケージ,
       o.name          AS イベント名,
       o.description   AS 説明
FROM   sys.dm_xe_objects  AS o
JOIN   sys.dm_xe_packages AS p ON p.guid = o.package_guid
WHERE  o.object_type = 'event'
  AND  (o.capabilities IS NULL OR o.capabilities & 1 = 0)   -- 内部専用(private)を除外
  AND  o.name LIKE '%deadlock%'
ORDER  BY p.name, o.name;
```

```sql
-- ② そのイベントが持つ「データ列」を調べる(★duration の単位もここで分かる)
SELECT oc.name         AS 列名,
       oc.type_name    AS 型,
       oc.column_type  AS 種別,        -- data / readonly / customizable
       oc.description  AS 説明
FROM   sys.dm_xe_object_columns AS oc
WHERE  oc.object_name = 'sql_statement_completed'
ORDER  BY oc.column_type, oc.name;
-- → duration の description に "microseconds" と書かれていることを自分の目で確認する
```

```sql
-- ③ 使えるアクションの一覧
SELECT p.name AS パッケージ, o.name AS アクション名, o.description
FROM   sys.dm_xe_objects  AS o
JOIN   sys.dm_xe_packages AS p ON p.guid = o.package_guid
WHERE  o.object_type = 'action'
  AND  (o.capabilities IS NULL OR o.capabilities & 1 = 0)
ORDER  BY p.name, o.name;

-- ④ 使えるターゲットの一覧
SELECT p.name AS パッケージ, o.name AS ターゲット名, o.description
FROM   sys.dm_xe_objects  AS o
JOIN   sys.dm_xe_packages AS p ON p.guid = o.package_guid
WHERE  o.object_type = 'target'
  AND  (o.capabilities IS NULL OR o.capabilities & 1 = 0);

-- ⑤ 述語ソース(イベント列以外でフィルタできるもの)
SELECT p.name AS パッケージ, o.name AS 述語ソース名, o.description
FROM   sys.dm_xe_objects  AS o
JOIN   sys.dm_xe_packages AS p ON p.guid = o.package_guid
WHERE  o.object_type = 'pred_source'
  AND  (o.capabilities IS NULL OR o.capabilities & 1 = 0)
ORDER  BY p.name, o.name;

-- ⑥ 列挙型(wait_type など)の数値↔名前の対応表
SELECT name AS マップ名, map_key AS 値, map_value AS 意味
FROM   sys.dm_xe_map_values
WHERE  name = 'wait_types'
ORDER  BY map_key;
```

**まず押さえておきたいイベント**(`sqlserver` パッケージ)

| イベント | 用途 | 注意 |
|---|---|---|
| `sql_statement_completed` | バッチ内の1文ごと | アプリからの呼び出しは拾えないことが多い |
| `sql_batch_completed` | バッチ全体 | アドホック SQL 向け |
| `rpc_completed` | プロシージャ/パラメータ化呼び出し | **アプリ経由はほぼこれ** |
| `module_end` | プロシージャ・関数・トリガーの終了 | 入れ子の内訳が見える |
| `xml_deadlock_report` | デッドロックグラフ | フィルタ不可・低頻度 |
| `blocked_process_report` | ブロッキング | **サーバー設定が必須**(第9節) |
| `error_reported` | エラー全般 | **高頻度。要フィルタ** |
| `attention` | クライアント側のキャンセル/タイムアウト | アプリのタイムアウト調査に有効 |
| `lock_timeout` / `lock_escalation` | ロックのタイムアウト・エスカレーション | 高頻度になりやすい |
| `wait_info` / `wait_info_external` | 個々の待機 | **超高頻度。単位はミリ秒**([23章](23_wait_statistics.md)) |
| `login` / `logout` | 接続 | 接続プールの挙動調査 |
| `query_post_execution_showplan` | **実際の実行プラン** | **超高コスト。本番禁止** |
| `auto_stats` | 統計の自動更新 | [27章]で扱う |

## 12. SSMS の GUI で使う

T-SQL が読み書きできれば GUI は必須ではありませんが、**結果を眺めるのは GUI が圧倒的に速い**です。

### 12-1. セッションの作成・管理

**オブジェクト エクスプローラー → 管理 → 拡張イベント → セッション**

- 右クリック **「新しいセッション ウィザード」** … 対話形式。テンプレートから選べる。
- 右クリック **「新しいセッション」** … 上級者向けダイアログ。**ここで作った内容は
  「スクリプト」ボタンで T-SQL に落とせます**。GUI で組み立てて T-SQL 化 → レビュー、が実務的です。
- 既存セッションを右クリック → **「セッションのスクリプト化」** で `CREATE EVENT SESSION` 文が得られます。
  **`system_health` の定義を読む**のは、良い教材になります。

### 12-2. ライブ データの監視 (Watch Live Data)

セッションを右クリック → **「ライブ データの監視」**。
イベントがリアルタイムで流れてきます。ビューア上で

- **「列の選択」** で表示列を追加(`sql_text` や `duration` を出す)
- 列を右クリック → **「列でグループ化」** / **「集計の計算」** で、その場で集計
- **「フィルターの適用」** で表示を絞り込み

ができます。

> ⚠️ **Watch Live Data は Profiler に近いコストが掛かります。**
> イベントを SSMS のプロセスへ **転送**するためです。
> - **本番の高頻度イベントで開かないこと。**
> - 表示が追いつかないと **イベントは落とされます**(画面下部に警告が出ます)。
>   「ライブビューアに出なかった = 発生していない」ではありません。
> - 調査が終わったら **必ずビューアのタブを閉じる**(開きっぱなしが一番危ない)。

### 12-3. 保存済みデータの表示

`event_file` ターゲットを右クリック → **「ターゲット データの表示」**。
`.xel` ファイルを SSMS に直接ドラッグ&ドロップしても開けます(**別サーバーで採ったファイルも読めます**)。

### 12-4. XEvent Profiler(SSMS 17.3 以降)

オブジェクト エクスプローラーの **インスタンス直下**にある **「XEvent Profiler」** ノードから、
`Standard` / `TSQL` をダブルクリックするだけで、Profiler のような画面が即座に立ち上がります。

> ⚠️ 手軽ですが **フィルタが一切掛かっていません**。開発環境専用と考えてください。
> 本番では自分で述語を書いたセッションを作ります。

## 13. 本番で使うときの注意 —— チェックリスト

1. **必ず述語(`WHERE`)を書く。** フィルタ無しのセッションは本番に置かない。
   最低でも `database_name` と、しきい値(`duration`)を入れる。
2. **述語は安い条件を左に。** 短絡評価されるので順序に意味がある。
3. **導入前に量を測る。** `event_counter` / `histogram` で
   「1分間に何件出るか」を確認してから、本番のしきい値を決める。
4. **`ring_buffer` ではなく `event_file`。** `ring_buffer` は揮発するうえ、
   4MB 超で XML が切り捨てられる。
5. **ディスク上限を暗算する。** `max_file_size × max_rollover_files`。
   ログドライブではなく、**十分な空きのある別ドライブ**に置く。
6. **`EVENT_RETENTION_MODE = NO_EVENT_LOSS` を使わない。** ワーカーを待たせる = 本番を遅くする。
7. **`MAX_DISPATCH_LATENCY` は既定 30 秒。** 学習中は 5 秒。本番はむしろ長め(30 秒)のままでよい。
8. **`TRACK_CAUSALITY` は必要なときだけ。** 全イベントに GUID + シーケンス番号が付くため、
   **イベントサイズが増え、ディスパッチ量が増えます**。
   「複数イベントの因果関係を追う」明確な目的があるときだけ `ON` にすること。
9. **高コストイベントを避ける。** `query_post_execution_showplan`、
   フィルタ無しの `wait_info` / `lock_acquired` / `error_reported` は本番禁止級。
10. **`dropped_event_count` を必ず確認する。** 落ちているなら結論が偏っている可能性がある。
11. **セッションの棚卸しをする。** 誰かが作ったまま忘れられたセッションは、
    静かにディスクと CPU を消費します。
    ```sql
    SELECT es.name, es.startup_state,
           CASE WHEN dm.address IS NULL THEN N'停止中' ELSE N'実行中' END AS 状態
    FROM   sys.server_event_sessions AS es
    LEFT   JOIN sys.dm_xe_sessions   AS dm ON dm.name = es.name
    WHERE  es.name NOT IN (N'system_health', N'AlwaysOn_health', N'telemetry_xevents');
    ```
12. **`.xel` ファイルの後始末を忘れない。** `DROP EVENT SESSION` してもファイルは残る。

## 14. 本章で作ったものの後片付け(必ず実行)

```sql
-- 1. セッションを停止して削除する
IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'xe_slow_queries')
    ALTER EVENT SESSION [xe_slow_queries] ON SERVER STATE = STOP;
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'xe_slow_queries')
    DROP EVENT SESSION [xe_slow_queries] ON SERVER;

IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'xe_deadlocks')
    ALTER EVENT SESSION [xe_deadlocks] ON SERVER STATE = STOP;
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'xe_deadlocks')
    DROP EVENT SESSION [xe_deadlocks] ON SERVER;

IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'xe_blocked')
    ALTER EVENT SESSION [xe_blocked] ON SERVER STATE = STOP;
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'xe_blocked')
    DROP EVENT SESSION [xe_blocked] ON SERVER;

IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'xe_errors')
    ALTER EVENT SESSION [xe_errors] ON SERVER STATE = STOP;
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'xe_errors')
    DROP EVENT SESSION [xe_errors] ON SERVER;

-- 2. 残っていないことを確認(system_health 等の既定セッションだけになるはず)
SELECT name FROM sys.server_event_sessions ORDER BY name;

-- 3. サーバー設定を戻す(第9節を実施した場合のみ)
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
EXEC sp_configure 'blocked process threshold (s)', 0; RECONFIGURE;
SELECT name, value_in_use FROM sys.configurations WHERE name = 'blocked process threshold (s)';  -- 0
EXEC sp_configure 'show advanced options', 0; RECONFIGURE;

-- 4. トランザクションが残っていないか確認(デッドロック実験をした両セッションで)
IF @@TRANCOUNT > 0 ROLLBACK;
SELECT @@SPID AS セッションID, @@TRANCOUNT AS 深さ;   -- 0 であること

-- 5. データが元に戻っているか確認
SELECT ProductId, UnitPrice FROM dbo.Products  WHERE ProductId = 2;    -- 2800
SELECT EmployeeId, Salary   FROM dbo.Employees WHERE EmployeeId = 3;   -- 480000
```

**`.xel` ファイルの削除**(`event_file` を使った場合)は OS 側で行います。
セッションを `STOP` / `DROP` してから、`C:\XE\xe_*.xel` を削除してください
(Linux なら `/var/opt/mssql/log/xe_*.xel`)。

## よくあるつまずき

- **セッションを開始したのにデータが空** → ① `MAX_DISPATCH_LATENCY` の既定が **30 秒**なので、
  まだバッファの中にいるだけ。② `ALTER EVENT SESSION ... STATE = START` を忘れている。
  ③ 述語が厳しすぎる(`duration` の単位を間違えている)。**この3つで9割です。**
- **`duration` のしきい値が効かない/全部引っかかる** → **単位はマイクロ秒**。
  1秒は `1000000`。ただし `wait_info` は**ミリ秒**。`sys.dm_xe_object_columns` の `description` で確認する。
- **`sql_statement_completed` を仕掛けたのにアプリの遅いクエリが採れない** →
  アプリからの呼び出しは **`rpc_completed`**。両方入れる。
- **`ring_buffer` が空になった** → `STATE = STOP` した瞬間に消える。**読んでから止める**。
  永続化したいなら `event_file`。
- **`CAST(target_data AS XML)` がパースエラー** → `ring_buffer` の 4MB 切り捨て。
  `max_events_limit` を下げるか `event_file` へ。`truncated="1"` を確認する。
- **`value()` が「単一値でない」とエラー** → パス末尾の **`[1]` を忘れている**。
- **`event_file` の `nodes()` が何も返さない** → パスが `/RingBufferTarget/event` になっている。
  **`event_file` は `/event`** から始まる。
- **`.xel` が見つからない** → 自動サフィックスが付くので **`ファイル名*.xel`** とワイルドカードで指定する。
- **`START` で「ファイルを作成できません」** → フォルダーが存在しないか、
  **SQL Server サービスアカウントに書き込み権限が無い**。`CREATE` 時ではなく `START` 時に失敗する。
- **`blocked_process_report` が1件も出ない** → `blocked process threshold (s)` が **`0`(既定)のまま**。
  設定してから、**そのしきい値以上待たされる**ブロッキングを起こす必要がある。
- **`histogram` が何も集計しない** → `source_type` の既定は **`1`(アクション)**。
  イベントのデータ列で集計するなら **`source_type = 0` を明示**する。
- **時刻が9時間ずれている** → `@timestamp` は **UTC**。
  `AT TIME ZONE 'UTC' AT TIME ZONE 'Tokyo Standard Time'`(2016+)で変換する。
- **セッションを作りっぱなしにする** → `sys.server_event_sessions` に残り続ける。
  `DROP EVENT SESSION` まで実行する。
- **`ALTER` で述語だけ変えようとする** → できない。`DROP EVENT` → `ADD EVENT` で入れ直す。
- **本番で Watch Live Data / XEvent Profiler を開く** → Profiler と同じ害。開発環境専用と考える。

## この章のまとめ

- 拡張イベントは **SQL トレース / Profiler の後継**。Profiler は
  「**取ってから捨てる + 同期転送**」なので本番禁止。XEvent は
  **述語を発火地点で評価**し、**非同期ディスパッチ**するので軽い。
- 構成要素は **イベント / アクション / 述語 / ターゲット / セッション** の5つ。
  **述語が心臓部**。左から短絡評価されるので、安い条件を先に書く。
- ターゲットは **`ring_buffer`(手軽・揮発)/ `event_file`(永続・本番向き)/
  `histogram`(集計)/ `event_counter`(件数)/ `pair_matching`(片割れ探し)**。
- `CREATE EVENT SESSION ... ADD EVENT (ACTION(...) WHERE ...) ADD TARGET ... WITH (...)`。
  **`MAX_DISPATCH_LATENCY` の既定 30 秒**、**`EVENT_RETENTION_MODE` に `NO_EVENT_LOSS` を使わない**、
  **`STARTUP_STATE = ON` で常設**、が要点。
- 結果は **XML**。`nodes()` で `<event>` を行に展開し、`value('(data[@name="…"]/value)[1]', …)` で取る。
  **`ring_buffer` は `/RingBufferTarget/event`、`event_file` は `/event`**。
  `event_file` は **`sys.fn_xe_file_target_read_file`**(2012 以降メタデータ引数は `NULL`)。
- 実用セッション4種: **遅いクエリ**(`sql_statement_completed` + `rpc_completed` を `duration` で)、
  **デッドロック**(`xml_deadlock_report`。犠牲者 → リソース → SQL → 獲得順序 の順に読む)、
  **ブロッキング**(`blocked_process_report`。**`blocked process threshold (s)` の設定が必須**)、
  **エラー**(`error_reported`。`severity` / `error_number` で必ず絞る)。
- **デッドロックは `system_health` に既定で記録されている**。ただし保持期間が短いので、
  長期に残すなら自前のセッション + `event_file`。
- 探し方は **`sys.dm_xe_objects` / `sys.dm_xe_object_columns` / `sys.dm_xe_map_values`**。
  **単位(マイクロ秒かミリ秒か)は必ず `description` で確認**する。
- 本番では **フィルタ必須・事前に量を測る・ディスク上限を暗算する・
  `dropped_event_count` を確認する・使い終わったら `DROP` する**。

➡ 演習: [exercises/25_extended_events.md](../exercises/25_extended_events.md)
