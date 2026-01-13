# UVM Compile & Simulation Issue Log

- This log records the issues/errors/warnings I faced pre/during compilation or run stage, and how to resolve or fix the issues while building the UVM verification environment



## Dec-17-2025

### Issus faced

1. **Multi-variable syntax errors**

   - Original code:

     ```systemverilog
     writes_seen_p0 = writes_seen_p1 = 0;
     reads_seen_p0  = reads_seen_p1  = 0;
     ```

   - Issue:

     - SystemVerilog does not allow the consecutive use of `=` to set multiple variables at once, as it will be parsed as an expression → Syntax error

   - Correct way:

     ```
     writes_seen_p0 = 0;
     writes_seen_p1 = 0;
     reads_seen_p0  = 0;
     reads_seen_p1  = 0;
     ```



2. **Call task inside a function**

   - Warning:

     `(vlog-2239) Treating stand-alone use of presumed external function as an implicit VOID cast.`

   - Reason:

     - A function cannot contain time (or delay), nor can it call a task

   - Solution:

     - Turn function into task, or change it to pure calculation function

       

3. **Syntax error due to WAIT_SIG macro expansion**

   - Error message:

     ```	tcl
     near "begin": syntax error, unexpected begin
     near "++": syntax error, unexpected ++
     ```

   - Reason:

     - The macro is missing a `\` at the line break, causing it to expand into incomplete SystemVerilog code
       

4. **Return value in task** 

   - Original code:

     `task automatic logic [DATA_WIDTH-1:0] compute_expected_beat_read(...);`

   - Error message:

     `task does not allow return value`

   - Correct way:

     ```
     task automatic compute_expected_beat_read(
         ..., output logic [DATA_WIDTH-1:0] rdata);
     ```

     

5. **Unable to find `uvm_config_db`**

   - Error message:

     ```tcl
     Undefined variable: 'uvm_config_db'
     near "#": syntax error
     ```

   - Reason:

     - Files are not included in the UVM package

   - Solution:

     ```systemverilog
     import uvm_pkg::*;
     `include "uvm_macros.svh"
     ```

     

6. **`axi_mm_pkg` include order incorrect**

   - Error message:

     `Could not find class 'axi_mm_driver'`

   - Reason:

     - The file include order within the package is incorrect

   - Fix (Correct order):

     - seq_item → driver → monitor → agent → env → test

     

7. **clocking block + ref → Simulator warning**

   - Reason:
     - Use clocking block ref (QuestaSim not recommended or not supported)

   - Fix:
     - Use direct signals, for example: `@(posedge vif.aclk);`
       

8. **virtual interface setup unsuccessful → Null handle**

   - Error message:

     `FATAL: Null virtual interface`

   - Reason:

     - `config_db` path incorrect, like: `env.p0_agent`

     - Or missing driver/monitor hierarchy

       

9. `randomize()` inline constraint missing `with`

   - Error message:

     `syntax error, expecting ')'`

   - Original code:

     ```systemverilog
     req.randomize() {}
     ```

   - Correct way:

     ```systemverilog
     req.randomize() with {
     };
     ```



10. **Monitor misuses clocking block event**

    - Original code:

      ```systemverilog
      @(posedge vif.cb_master)
      ```

    - Reason:

      - Invalid syntax

    - Fix:

      ```
      @(vif.cb_master);
      ```

      or completely remove clocking block



12. **Reset wait / handshake not allowed in functions**
    - Reason:
      - Time control inside a function (which requires calling a task) causes errors or warnings
    - Solution:
      - Move all such logic into a task



13. **Unclear behavior in burst default case**
    - Issue:
      - The `default` case is not handled, leading to incorrect override/decision logic
    - Fix:
      - Explicitly encode `burst = FIXED/INCR/WRAP`




## Dec-20-2025
### 專案背景
- DUT: AXI-MM 雙埠 BRAM（dual-port RAM）  
- 執行環境: UVM Smoke Test  
- Port0: dma_clk domain  
- Port1: core_clk domain  
- 測試目標: 確認 write/read 功能正確，無 timeout 或 mismatch  

---

## 今日遇到的主要問題

### 1. Read Timeout 與 Write Timeout
- 初始 smoke_test 設定：

seq.num_transactions = 1
seq.max_beats        = 1
seq.read_percent     = 100
問題:

READ MISMATCH 或 Timeout waiting for WREADY/BVALID

原因: 測試全是 read，但 DUT 尚未寫入任何資料 → scoreboard 讀到 0xXX → mismatch

解決方法:

將 read_percent 改為 0，先執行 write transaction

修正 DUT write path，確保 Port0/Port1 AW/W/B handshake 正確

確認 BVALID/BRESP 回應正確

結果: Write 成功完成，Driver log 顯示 WRITE done: BRESP=0

2. Port0 / Port1 Write FSM 修正
Port0 (dma_clk domain)
問題: Timeout waiting for WREADY
原因: p0_wr_req 與 axi0_if.wready 邏輯未完全配合
修改:

在 write beat capture 後立即設置 p0_wr_req = 1

在橋接完成後清除 p0_wr_req

保留 AW/W/B FSM 原有結構，確保 AW/W/B handshake 正確

Port1 (core_clk domain)
同樣修正了 AW/W/B handshake 與 p1_local_wr_req/橋接 toggles 邏輯

確保每個 beat 在 core domain 被正確送出到 bridge

清楚區分 local pending 與 bridge accepted

3. Read FSM / Read Assembly 修正
初始寫法：

systemverilog
Copy code
if (p1_ar_active && !p1_rvalid) begin
    logic [ADDR_WIDTH-1:0] beat_addr;
    ...
end
編譯錯誤:

pgsql
Copy code
Illegal declaration after the statement
解決方法:

將 local declaration 移到 always_ff 區塊最前面，或使用 automatic 宣告

統一 Port0/Port1 read assembly

最終寫法:

systemverilog
Copy code
always_ff @(posedge core_clk or negedge core_rst_n) begin
    automatic logic [ADDR_WIDTH-1:0] beat_addr;
    automatic logic [ADDR_IDX_W-1:0] aligned_byte;
    if (!core_rst_n) p1_rdata <= '0;
    else if (p1_ar_active) begin
        if      (p1_arburst == 2'b10) beat_addr = compute_wrap_addr(...);
        else if (p1_arburst == 2'b01) beat_addr = compute_incr_addr(...);
        else                           beat_addr = p1_araddr;
        ...
    end
end
4. UVM Smoke Test 調整
初始設定 100% read → mismatch

調整為 0% read → write transaction 正常完成

驗證：

text
Copy code
# UVM_INFO ... WRITE done: BRESP=0
下一步: 可改回 read_percent=100，確保讀出資料與寫入資料一致

今日結論與建議
Read-before-write 會造成 mismatch

Smoke test 若全 read，需要先初始化 memory 或先寫入資料

Dual-port FSM

Port0/Port1 寫入邏輯要確保 local pending buffer 與 bridge/toggle handshake 正確

BVALID/BRESP 必須在橋接完成後回應

Read assembly

避免在 if/else 裡直接宣告 logic

可使用 automatic 或提前宣告

Smoke Test 流程

建議 sequence: WRITE → READ

可用 read_percent 動態控制讀寫比率



## 日期
2025-12-21


### Smoke test testing items:
| Step | num_transactions | max_beats | read_percent | 說明                                |   
| ---- | ---------------- | --------- | ------------ | ----------------------------------  | 
| 1    | 1                | 1         | 0            | 單 beat 寫入，最簡單驗證              |   
| 2    | 1                | 4         | 0            | 單 transaction，多 beat 寫入         | 
| 3    | 2                | 4         | 0            | 多 transaction，多 beat 寫入         | 
| 4    | 2                | 4         | 50           | 多 transaction，讀寫混合             | 
| 5    | 4                | 4         | 0            | 多 transaction，多 beat 寫入         | 
| 6    | 4                | 4         | 50           | 多 transaction，讀寫混合              | 
| 7    | 4                | 8         | 50           | 多 transaction，較長 burst, 讀寫混合   | 
| 8    | 4                | 16        | 50           | 多 transaction，最大 burst,讀寫混合   | 

## 測試目標
完成 AXI-MM 的基本功能驗證，透過 smoke test 檢查：
- 單 beat 與多 beat transaction
- 單 transaction 與多 transaction
- 讀寫混合行為
- Burst 長度變化
- 驗證 DUT 對 backpressure 的正確處理

## 今天遇到的主要問題與解決辦法

### 1️⃣ Multi-beat transaction driver 錯誤

**現象：**
- Single beat transaction 正常
- Multi-beat transaction 時，部分 W channel beat 被覆寫，造成 DUT 不穩定
- Scoreboard 報錯，WLAST timing 不正確

**原因分析：**
- 原始 driver 代碼：

@(cb);
wdata <= beat[i];
wait(wready);
在 WREADY = 0 的情況下，下一拍仍然覆寫 wdata，違反 AXI handshake 規範。

修正 driver 核心邏輯：

systemverilog
Copy code
while (i < beats) begin
    @(cb);
    wvalid <= 1;
    wdata  <= beat[i];

    if (wready)
        i++;   // 只有 handshake 才前進
end
效果：

Driver 完全符合 AXI spec

正確處理 DUT backpressure

Multi-beat 不丟失 beat，WLAST timing 正確

Scoreboard 不再報錯

2️⃣ DUT WRITE FSM 問題
現象：

driver 修正後，仍有 multi-beat transaction 初期寫入被阻塞

log 中顯示：

ini
Copy code
p0_wr_req =「Memory Core 尚未消化上一筆 write beat」
整個 burst 被當成一次 write，導致 Memory Core 未消化第 0 beat，就阻塞第 1 beat

原因分析：

AXI 規範要求：

W channel beats 是串流的

Memory Core 可以慢，但不能阻塞整個 burst

原設計違反此規範：Memory Core 未消化，整個 burst 停住

最小修正方案（不改架構）：

p0_wr_req 只能擋 Memory Core

不能阻塞 W channel beat 接收

BVALID 只和最後一拍的接收成功有關

效果：

DUT 可以合法接收連續 W beats

Backpressure 只限制 Memory Core

Multi-beat transaction 正確完成，scoreboard 無錯誤

3️⃣ READ beat skip 現象
現象：

Scoreboard log 中看到：

vbnet
Copy code
Skip read compare: unwritten addr=0x5a0a938 beat=0 port=0
只出現在 multi-beat 讀取初期

原因分析：

第一次讀取時，地址尚未寫入資料

Scoreboard 設計正確跳過尚未寫入的 beat

結論：

正常現象，不是 DUT 或 driver 問題

模擬結果可視為成功

4️⃣ Step 6 執行確認
問題：

一開始對 step 6 是否已完成不確定

解決辦法：

查看模擬 log num_transactions=4, max_beats=4, read%=50

確認交易完成，scoreboard 無錯誤，標記 ✅

5️⃣ 多 step 並行追蹤
問題：

同時跑多 step 容易造成參數混淆

解決辦法：

每 step 用表格明確記錄：

num_transactions

max_beats

read_percent

模擬結果與狀態

每完成一個 step 即更新表格

今天學到的重點
Multi-beat 交易必須正確 handshake 才能符合 AXI spec

Driver 設計時要確保 WREADY 0 時不覆寫 wdata

DUT WRITE FSM 必須允許連續 W beats，Memory Core 速度慢不應阻塞整個 burst

AW/W 可以 fork/join，但 B channel 必須最後處理



## 日期
2026-01-01

Faced issues:
1. [Directed Test] Found out directed test only has one test case, proper test cases should be as follow:
| Case | 名稱                | 驗證重點               |
| ---- | ------------------- | --------------------- |
| 0    | single-beat RAW     | 最小合法 write → read  |
| 1    | multi-beat RAW      | burst 正確、WLAST      |
| 2    | back-to-back write  | 無 bubble              |
| 3    | overwrite same addr | 最後寫入勝出            |
| 4    | partial write       | WSTRB 行為             |

    - Currently testing Case 0, if no issue, will add more test cases accordingly 

2. [Directed Test] UVM API call failed => Should use axi_mm_seq not axi_mm_seq_item
    - Add directed_mode flag bit in seq_item

Direct Test Case 0 test result:
- AWLEN = 0 (single beat), BESOP = OKAY(0), no backpressure deadlock
- Read data = Write data (0xdeadbeef12345678) => Correct
- Single beat alignment                       => Correct
- No X/Z corruption                           => Correct
- Sequence/Test done normally
- Summary:
    - Correct UVM test flow (test -> sequence -> driver -> DUT -> monitor -> scoreboard)
    - Verified RAW coherency
    - Verified driver/DUT has no regression on single beat

- Conclusion: Case 0 test PASSED

Direct Test Case 1 test result (Attempt 1):
-  Write burst 看起來是對的 => Driving WRITE addr=0x200 len=3 id=0x2
-  但 scoreboard 完全沒有「任何一個 beat 被記為 written」
   - Skip read compare: unwritten addr=0x200 beat=0
   - Skip read compare: unwritten addr=0x208 beat=1
   - Skip read compare: unwritten addr=0x210 beat=2
   - Skip read compare: unwritten addr=0x218 beat=3
   - 這代表一件非常明確的事：scoreboard 根本沒收到 / 沒建立任何 write model
- READ done: beats=4 first beat=0xx
  - 這行非常關鍵, 代表:
    - read data 不是你預期的 pattern, 而是 X / 未定值
    - 但 driver 仍然完成 transaction
- Root cause: 
  - directed_mode + multi-beat WRITE 時，axi_mm_seq 產生的 transaction「在語法上合法，但在 verification 語意上是不完整的」
  - Problematic code:
    - if (dir_rw == AXI_WRITE) begin
        foreach (tr.data_beats[i]) begin
            tr.data_beats[i]  = dir_wdata;
            tr.wstrb_beats[i] = {BYTES_PER_BEAT{1'b1}};
        end
      end
  - 沒有提供beat 對應的 address / identity 語意
    - 結果:
      - Monitor / scoreboard 無法判斷這是一組 coherent burst write
      - Scoreboard 沒有建立 memory model
      - 所有 read → Skip read compare
      - DUT read data 變成 0xx（未定義或未寫入）
  - 我現在的axi_mm_seq把 multi-beat burst 當成「重複 single-beat data」來看
- Solution:
  - tr.data_beats[i]  = dir_wdata + i;
    tr.wstrb_beats[i] = {BYTES_PER_BEAT{1'b1}};
  - 這使得:
    - beat 0 → addr + 0 → data = base
      beat 1 → addr + 8 → data = base + 1
      beat 2 → addr + 16 → data = base + 2
      beat 3 → addr + 24 → data = base + 3
    - 這樣scoreboard 可以建立完整 memory map

Direct Test Case 1 test result (Attempt 2):
- 把sequence層修好了
  - 因為Write完全成功
    - sequence正確
    - driver正確
    - DUT回BREP=OKAY
- 但是:
  - Read 時 scoreboard完全沒記憶:
    - Skip read compare: unwritten addr=0x200 beat=0
    - Skip read compare: unwritten addr=0x208 beat=1
    - Skip read compare: unwritten addr=0x210 beat=2
    - Skip read compare: unwritten addr=0x218 beat=3
  - 這100%證明:
    - Scoreboard 的 memory model 裡，完全沒有收到任何 write beat
- Root cause:
  - Monitor 沒有正確把「寫入行為」送到 Scoreboard
  - 我把 AW、W、B 當成「一定是嚴格連續、不會被打斷、不會 interleave」但 AXI 不保證這件事，即使在你目前的 DUT 也「剛好沒打斷」，monitor 仍然會 miss event。
  - @125000 WRITE done
  - @125000 DIRECTED WRITE
  - @175000 READ
  - @175000 SCB Skip read compare: unwritten addr=0x100
    - Scoreboard 在收到 READ transaction 時還沒有收到對應的 WRITE transaction
    - 也就是：
      - Monitor 的 ap.write(tr) 發生得太晚 / 或根本沒送成功
- Solution:
  - Monitor monitor_write()必須修正:
    - AW / W / B 必須完全解耦
    - 可以同時存在多筆未完成 write transaction
    - Scoreboard 一定能在 READ 之前看到 WRITE
  - 在修正monitor_write()時也發現monitor_read()也要同時修正
    - 原因是因為我當前monitor_read()有在AXI標準尚不成立的假設
      - 假設 AR 之後，R 會連續回來
      - 假設一次只會有一筆 outstanding read
      - AR / R 沒有解耦
      - 不支援 interleaving / backpressure
      - READ 可能被 scoreboard 當成「unwritten」
    - AXI4的規範是:
      - AR / R 完全獨立
      - 多筆 outstanding read 合法
      - R 有 ID，可以 interleave
  - 修該過程中發現:
    - axi_mm_seq_item中沒有next_wbeat_idx和next_rbeat_idx這兩個變量
      - 已增加