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

確認交易完成，scoreboard 無錯誤，標記 

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
	  
	  
  
## 日期
2026-01-12

Faced issues:
1. 和之前一樣, DUT在`len = 0`(single-beat write)時, `WREADY`沒有在最後一拍正確拉低, 導致同一筆W beat被monitor看到"handshake twice"
	- This means there is logical bug on W channel FSM in DUT
	- AXI規則:
		- W beat 計數是由 `WVALID && WREADY` 決定
			- 不是看資料有沒有變
			- 不是看是不是同一個 beat
	- Root cause 1
		- 你用 p0_aw_active 直接驅動 axi0_if.wready，但 p0_aw_active 是在bridge 接收最後一拍之後才清掉的，導致最後一拍 W 被重複 handshake
			- 也就是這行:  axi0_if.wready <= p0_aw_active;
	- Fix Attempt 1 
		- WREADY 必須由「W channel state」控制, 而不是由「AW 還 active 不 active」控制
		- 新增一個signal: p0_w_active
			- AW handshake 時啟動W channel (p0_w_active拉高)
			- WREADY改由p0_w_active決定
			- 在最後一拍W handshake當拍(is_last_now)就關掉WREADY
	- Result 1
		- Issue remains
			
	- Root cause 2
		- DUT 在「AXI 規格層面」仍然允許同一個 W beat 被 monitor 視為兩次 handshake
			- Log表示得很清楚:
			```
			# UVM_INFO  @ 56000: [AXI_MON] AW captured: ID=0 addr=0x100 len=0
			# UVM_INFO  @ 76000: [AXI_MON] W captured: ID=0 Beat=0 Data=0xdeadbeef12345678 
			# UVM_ERROR @ 86000: [AXI_MON] Extra W beat for ID 0. Exp: 1. WDATA=0xdeadbeef12345678 WLAST=1
			```
			- Observation
				1. Driver只送一個beat (len = 0)
					- 從monitor的Error message得知:
						- AWLEN = 0 -> 預期1個beat
                        - Monitor已經記錄	1個成功的W handshake
                        - 但又看到另一個handshake條件成立
							- 所以monitor看到兩次wvalid && wready
		- 我的wready是"狀態式"的, 不是"脈衝式"的:
			- axi0_if.wready <= p0_w_active && !p0_local_wr_req;
			- 我現在的wready是在always_ff底下條件變更的, 這代表:
				- wready下降是在下一拍才發生
				- AXI不允許這樣用來做beat限制
	- Fix Attempt 2
		- 必須讓 WREADY 在「接受 beat 的那一拍」立刻被 deassert
		- 解法: 用 combinational-ready + registered accept
			```
			wire p0_w_hs;
			assign p0_w_hs = axi0_if.wvalid && axi0_if.wready;
			assign axi0_if.wready = p0_w_active && !p0_local_wr_req; 
			```
		- Faced issue
			- Compilation error (vsim-12003): Variable written by continuous and procedural assignments
				- 這代表同一個signal同時被procedural assignment (<=) 和continuous assignment (assign) => Illegal
			- Fix
				- 在memory core中找到procedural assignment, 刪掉並全部改成continuous assignment. Memory core只操作p0_wr_req與內部mem_byte, 不碰wready
	
	- Result 2
		- vsim-12003 issue has been resolved, but UVM log still shows error
		
	- Root cause 3
		- Port0 FSM 與 Memory Core 之間的 handshake沒有完整鏈接
			- FSM 使用 p0_local_wr_req 表示有新的 W beat
			- Memory Core 使用 p0_wr_req 來 commit
			- 兩者沒有橋接信號 → write 永遠不被執行
	- Fix Attempt 3
		- 需要在 Port0 FSM 把 p0_local_wr_req 正確轉換成 Memory Core 的 p0_wr_req
			- axi0_if.wready 完全由 Port0 FSM continuous assign 控制
			- Memory Core 使用 p0_wr_req 作為 commit trigger
			- p0_aw_active 只在 AW 及 B channel commit中更新
	
	- Result 3
		- Issue remains
		
	- Root cause 4
		- Simulation 停在「AW/W captured 但 Memory Core 沒 commit」，所以 scoreboard 永遠都是 0
		- p0_ack_toggle_sync2_dma 是 DMA 端對 Core 端 toggle 的同步, 但一開始 p0_ack_toggle_sync2_dma == 0，p0_req_toggle_dma == 0，第一次 AW/W handshake 的 toggle edge 根本不會被檢測到，所以 if 永遠不成立
		- 結果就是：p0_wr_req 從來不會被 Memory Core 看到 → Memory Core 不 commit → scoreboard 永遠 0
				
	- Fix Attempt 4
		- 移除 toggle 同步判斷
		- Port0 FSM 只要 p0_local_wr_req==1 就直接產生 p0_wr_req=1. Memory Core 再 consume 這個 request
	
	- Result 4
		- Fixed toggle issue
		- Directed test Case 0 passed (Able to see 0xdeadbeef12345678)
		- But for INCR burst case, write results are all 0xXX... -> Scoreboard mismatch
	
	- Root cause 5
		- Memory Core 沒正確 commit multi-beat writes
		- 目前的 Memory Core 沒有 FIFO / queue / handshake 來串 multi-beat writes，Port0 FSM 每次 p0_local_wr_req 上升就 overwrite 之前的 beat
		
	- Fix Attempt 5
		- 對 INCR burst：
			- FSM 看到 AW → 記下 p0_awaddr/p0_awlen/p0_awsize
			- 每個 W beat → 計算 beat address → 直接寫入 RAM
			- WLAST → 產生 BVALID/BRESP
		- 不再用 p0_local_wr_req + p0_wr_req toggle
	
	- Result 5
		- Directed test Case 0 passed, Case 1 issue remains
	
	- Root cause 6
		- BVALID with incomplete write
			```
			# UVM_ERROR @ 96000:  [AXI_MON] BVALID with incomplete write. ID=0 Beats=0/1
			# UVM_ERROR @ 236000: [AXI_MON] BVALID with incomplete write. ID=2 Beats=0/4
			```
			- 代表monitor偵測到 BVALID 已經升高，但對應的所有 W beats 還沒被 commit 到 memory core
				- Two possible reasons:
					1. Memory core 的 commit 邏輯落後
						- p0_wr_req 是在同一個 cycle 觸發的，而 B channel 可能也在同一 cycle升高 → monitor 看到 “BVALID = 1，但 Memory 還沒寫任何 beat” → mismatch
					2. 多 beat 寫入沒有逐 beat commit
						- 你的 INCR burst (len=3) 有 4 beats (0~3)，但 memory core 只 commit 一次 (p0_wr_req) → 其餘 beats 沒寫 → scoreboard mismatch
		
		- READ mismatch
			```
			# UVM_ERROR @ 346000: [SCB] READ MISMATCH port=0 addr=0x200 beat=0 exp=0x0 got=0xx id=0x3
			```
			- 這是上面問題的結果: Memory沒有寫對數據, 所以讀回來都是X或是0 -> scoreboard mismatch
	

## 日期
2026-01-13

Faced issues:
1. Directed test Case 1 failed
  - Issue 1
    - BVALID with incomplete write
    - W data = X
    - READ mismatch
  
  - Root Cause 1
    - 完全沒有實作wready
    - W beat capture 完全沒有handshake保護
      - 沒有wready
      - p0_local_wr_req每一拍都被拉高, 沒有清楚的一拍語意
      - bvalid在看到wlast當拍就拉高
        - AXI規定最後一個W beat的handshake完成後才能assert BVALID
    - AW/W/B完全沒有FSM關係
		
	- Fix Attempt 1
		- 每個 W beat 都 commit 到 memory core，不要等到最後一個 beat才 commit
		- BVALID 只在最後一個 beat升高
		- 保持 p0_wr_req 與 beat 一一對應，而不是一次 commit 整個 burst

  - Result 1
    - Same error



## 日期
2026-01-14

Faced issues:
1. Directed test Case 1 failed
   - Issue 1:
     - Read mismatch
     - Driver data always 0xXX
      
   - Root cause 1 
     - Driver在拿到transaction時, tr.data_beats[i] 本身就是X
       - Proof: [DRV_DBG] W drive beat=0 data=0xx
         - 這代表sequence 產生的 data 本來就是 X
     - dir_wdata從來沒有被賦值
       - 我只有:
       ```
       logic [DATA_WIDTH-1:0] dir_wdata; 
       tr.data_beats[i] = dir_wdata + i;
       ```
       - 那麼dir_wdata在SV裡就會是X, 結果就是:
         - X + 0 = X
         - X + 1 = X
         - X + 2 = X
         - X + 3 = X
       - 這樣整個write_burst全是X, 才導致:
         - driver:  data = 0xXX
         - monitor: Data = 0xXXXXXXXXXXXXXXXX
         - RAM寫進去是X
         - read回來也是X
         - scoreboard mismatch
  
   - Fix Attempt 1
     -  明確初始化 dir_wdata
        -  在Directed Test中, 加上seq.dir_wata初始值: seq.dir_w = 64h'DEAD_BEEF_0000_0000

   - Result 1
     - Durected test Case 1 passed
       -  log
       ```  
       # UVM_INFO @ 0:      [SCB] Scoreboard started
       # UVM_INFO @ 0:      [MON] AXI-MM Monitor started
       # UVM_INFO @ 0:      [MON] AXI-MM Monitor started
       # UVM_INFO @ 55000:  [DRV] Driving WRITE addr=0x200 len=3 id=2
       # UVM_INFO @ 56000:  [AXI_MON] AW captured: ID=2 addr=0x200 len=3
       # UVM_INFO @ 75000:  [DRV_DBG] W drive beat=0 data=0xdeadbeef00000000
       # UVM_INFO @ 76000:  [AXI_MON] W captured: ID=2 Beat=0 Data=0xdeadbeef00000000
       # UVM_INFO @ 95000:  [DRV_DBG] W drive beat=1 data=0xdeadbeef00000001
       # UVM_INFO @ 96000:  [AXI_MON] W captured: ID=2 Beat=1 Data=0xdeadbeef00000001
       # UVM_INFO @ 115000: [DRV_DBG] W drive beat=2 data=0xdeadbeef00000002
       # UVM_INFO @ 116000: [AXI_MON] W captured: ID=2 Beat=2 Data=0xdeadbeef00000002
       # UVM_INFO @ 135000: [DRV_DBG] W drive beat=3 data=0xdeadbeef00000003
       # UVM_INFO @ 136000: [AXI_MON] W captured: ID=2 Beat=3 Data=0xdeadbeef00000003
       # UVM_INFO @ 156000: [AXI_MON] WRITE completed: ID=2 Addr=0x00000200 Data[0]=0xdeadbeef00000000 (Beats=4)
       # UVM_INFO @ 175000: [DRV] WRITE done: id=2 BRESP=0
       # UVM_INFO @ 175000: [uvm_sequence_item] DIRECTED WRITE addr=0x200 beats=4 id=0x2
       # UVM_INFO @ 175000: [DRV] Driving  READ addr=0x200 len=3 id=3
       # UVM_INFO @ 285000: [DRV] READ done: id=3 beats=4 first=0xdeadbeef00000000
       # UVM_INFO @ 285000: [uvm_sequence_item] DIRECTED  READ addr=0x200 beats=4 id=0x3
       # UVM_INFO @ 285000: [DIRECT_TEST] Directed RAM test case 1 completed
       # UVM_INFO @ 285000: [TEST_DONE] 'run' phase is ready to proceed to the 'extract' phase
       ```

## 日期
2026-01-15

- Objective: Directed Test Case 2 (WRAP address write/read)

- Goal
  - BRAM在wrap地址時有正確讀/寫行為
    - Wrap address example:
      - beat0: 0x318
      - beat1: 0x300 (0x318 + 8 = 0x320 → wrap 回 0x300)
      - beat2: 0x308
      - beat3: 0x310
  - 驗證BRAM在wrap address時有正確的address order
  
- Changes
  - 在monitor中新增cal_beat_addr() function
    - WHY?
      - 沒有一個 AXI 訊號會在每個 W beat 上直接告訴你「這一拍的 address」
      - W channel 本來就沒有 address; address 只在 AW channel 一次給出（start addr + burst info）
      - 所以如果你想在 monitor log 裡看到「每個 beat 的地址」, monitor 只能自己用 AW 的 addr/len/size/burs 去推導
   