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
     - Durected test Case 1 PASSED
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

- Goal 1
  - BRAM在wrap地址時有正確讀/寫行為
    - Wrap address example:
      - beat0: 0x318
      - beat1: 0x300 (0x318 + 8 = 0x320 → wrap 回 0x300)
      - beat2: 0x308
      - beat3: 0x310
  - 驗證BRAM在wrap address時有正確的address order
  
- Changes 1 
  - 在monitor中新增cal_beat_addr() function
    - WHY?
      - 沒有一個 AXI 訊號會在每個 W beat 上直接告訴你「這一拍的 address」
      - W channel 本來就沒有 address; address 只在 AW channel 一次給出（start addr + burst info）
      - 所以如果你想在 monitor log 裡看到「每個 beat 的地址」, monitor 只能自己用 AW 的 addr/len/size/burs 去推導

- Result 1
  - Directed test Case 2 PASSED
    - log
    ```
    # UVM_INFO @ 0:      [SCB] Scoreboard started
    # UVM_INFO @ 0:      [MON] AXI-MM Monitor started
    # UVM_INFO @ 0:      [MON] AXI-MM Monitor started
    # UVM_INFO @ 55000:  [DRV] Driving WRITE addr=0x318 len=3 id=4
    # UVM_INFO @ 56000:  [AXI_MON] AW captured: ID=4 addr=0x318 len=3
    # UVM_INFO @ 75000:  [DRV_DBG] W drive beat=0 data=0xcafebabe00000000
    # UVM_INFO @ 76000:  [AXI_MON] W captured: ID=4 Beat=0 Addr=0x318 Data=0xcafebabe00000000 WLAST=0 burst=10 size=3
    # UVM_INFO @ 95000:  [DRV_DBG] W drive beat=1 data=0xcafebabe00000001
    # UVM_INFO @ 96000:  [AXI_MON] W captured: ID=4 Beat=1 Addr=0x300 Data=0xcafebabe00000001 WLAST=0 burst=10 size=3
    # UVM_INFO @ 115000: [DRV_DBG] W drive beat=2 data=0xcafebabe00000002
    # UVM_INFO @ 116000: [AXI_MON] W captured: ID=4 Beat=2 Addr=0x308 Data=0xcafebabe00000002 WLAST=0 burst=10 size=3
    # UVM_INFO @ 135000: [DRV_DBG] W drive beat=3 data=0xcafebabe00000003
    # UVM_INFO @ 136000: [AXI_MON] W captured: ID=4 Beat=3 Addr=0x310 Data=0xcafebabe00000003 WLAST=1 burst=10 size=3
    # UVM_INFO @ 156000: [AXI_MON] WRITE completed: ID=4 Addr=0x00000318 Data[0]=0xcafebabe00000000 (Beats=4)
    # UVM_INFO @ 175000: [DRV] WRITE done: id=4 BRESP=0
    # UVM_INFO @ 175000: [uvm_sequence_item] DIRECTED WRITE addr=0x318 beats=4 id=0x4 burst=10 size=3
    # UVM_INFO @ 175000: [DRV] Driving  READ addr=0x318 len=3 id=5
    # UVM_INFO @ 206000: [AXI_MON] R captured: ID=5 Beat=0 Addr=0x318 Data=0xcafebabe00000000 RLAST=0
    # UVM_INFO @ 226000: [AXI_MON] R captured: ID=5 Beat=1 Addr=0x300 Data=0xcafebabe00000001 RLAST=0
    # UVM_INFO @ 246000: [AXI_MON] R captured: ID=5 Beat=2 Addr=0x308 Data=0xcafebabe00000002 RLAST=0
    # UVM_INFO @ 266000: [AXI_MON] R captured: ID=5 Beat=3 Addr=0x310 Data=0xcafebabe00000003 RLAST=1
    # UVM_INFO @ 285000: [DRV] READ done: id=5 beats=4 first=0xcafebabe00000000
    # UVM_INFO @ 285000: [uvm_sequence_item] DIRECTED  READ addr=0x318 beats=4 id=0x5 burst=10 size=3
    # UVM_INFO @ 285000: [DIRECT_TEST] Directed RAM test case 2 completed
    # UVM_INFO @ 285000: [TEST_DONE] 'run' phase is ready to proceed to the 'extract' phase
    ```
   
## 日期
2026-01-17

- Objective: Directed Test Case 3 (Partial write)

- Goal 1 (Case 3.1)
  - BRAM在Partial write時有正確讀/寫行為

- Expected Output 1:
  - 第一次Full write
    - @0x400 address 寫入data 0x1122_3344_5566_7788
  - 第二次partial write
    - @0x400 address 寫入data 0x0000_0000_0000_AAAA
      - 理論上應該只覆蓋 byte[1:0]部分
  - Read back
    - 應該要得到 0x1122_3344_5566_AAAA

- Result 1
  - Directed Test Case 3.1 PASSED
    - log
    ```
    # UVM_INFO @ 0:      [Questa UVM] QUESTA_UVM-1.2.3
    # UVM_INFO @ 0:      [Questa UVM] questa_uvm::init(all)
    # UVM_INFO @ 0:      [RNTST] Running test axi_mm_directed_test...
    # UVM_INFO @ 0:      [AGENT] Building agent 'uvm_test_top.env_h.p0_agent' (ACTIVE)
    # UVM_INFO @ 0:      [AGENT] Building agent 'uvm_test_top.env_h.p1_agent' (ACTIVE)
    # UVM_INFO @ 0:      [ENV] axi_mm_env connected monitors to scoreboard
    # UVM_INFO @ 0:      [Questa UVM] End Of Elaboration
    # UVM_INFO @ 0:      [DIRECT_TEST] Case 3: Partial strobe write/read
    # UVM_INFO @ 0:      [SCB] Scoreboard started (STRICT_RANGE=0)
    # UVM_INFO @ 0:      [MON] AXI-MM Monitor started
    # UVM_INFO @ 0:      [MON] AXI-MM Monitor started
    # UVM_INFO @ 55000:  [DRV] Driving WRITE addr=0x400 len=0 id=6
    # UVM_INFO @ 56000:  [MON] AW captured: ID=6 addr=0x400 len=0 burst=01 size=3
    # UVM_INFO @ 75000:  [DRV_DBG] W drive beat=0 data=0x1122334455667788
    # UVM_INFO @ 76000:  [MON] W captured: ID=6 Beat=0 Addr=0x400 Data=0x1122334455667788 WLAST=1 burst=01 size=3
    # UVM_INFO @ 96000:  [MON] WRITE completed: ID=6 Addr=0x00000400 Data[0]=0x1122334455667788 (Beats=1)
    # UVM_INFO @ 115000: [DRV] WRITE done: id=6 BRESP=0
    # UVM_INFO @ 115000: [uvm_sequence_item] DIRECTED WRITE addr=0x400 beats=1 id=0x6 burst=1 size=3
    # UVM_INFO @ 115000: [DRV] Driving WRITE addr=0x400 len=0 id=7
    # UVM_INFO @ 116000: [MON] AW captured: ID=7 addr=0x400 len=0 burst=01 size=3
    # UVM_INFO @ 135000: [DRV_DBG] W drive beat=0 data=0x000000000000aaaa
    # UVM_INFO @ 136000: [MON] W captured: ID=7 Beat=0 Addr=0x400 Data=0x000000000000aaaa WLAST=1 burst=01 size=3
    # UVM_INFO @ 156000: [MON] WRITE completed: ID=7 Addr=0x00000400 Data[0]=0x000000000000aaaa (Beats=1)
    # UVM_INFO @ 175000: [DRV] WRITE done: id=7 BRESP=0
    # UVM_INFO @ 175000: [uvm_sequence_item] DIRECTED WRITE addr=0x400 beats=1 id=0x7 burst=1 size=3
    # UVM_INFO @ 175000: [DRV] Driving  READ addr=0x400 len=0 id=8
    # UVM_INFO @ 176000: [MON] AR captured: ID=8 addr=0x400 len=0 burst=01 size=3
    # UVM_INFO @ 206000: [MON] R captured: ID=8 Beat=0 Addr=0x400 Data=0x112233445566aaaa RRESP=0 RLAST=1
    # UVM_INFO @ 225000: [DRV] READ done: id=8 beats=1 first=0x112233445566aaaa
    # UVM_INFO @ 225000: [uvm_sequence_item] DIRECTED  READ addr=0x400 beats=1 id=0x8 burst=1 size=3
    # UVM_INFO @ 225000: [DIRECT_TEST] Directed RAM test case 3 completed (partial strobe)
    # UVM_INFO @ 225000: [TEST_DONE] 'run' phase is ready to proceed to the 'extract' phase
    ```

- Goal 2 (Case 3.2)
  - Cross-port choherence
    - P0 full write -> P1 partial write -> P0 and P1 both read

- Expected Output 2:
  - P0 full write @0x410：0x1122_3344_5566_7788 + wstrb=0xff
  - P1 partial write @0x410：0xAAAA_0000_0000_0000 + wstrb=0xc0 
    - 0xC0 = 1100_0000 → 更新 byte[7:6]（最高兩個 byte lane）
    - So expected data：byte[7:6]=0xAA,0xAA，其餘 byte[5:0] 保留 0x22334455667788 也就是：0xAAAA_3344_5566_7788

  - P0 read @0x410：0xAAAA_3344_5566_7788
  - P1 read @0x410：0xAAAA_3344_5566_7788

- Result 2
  - AR miscatch causing R unknowin ID
  - DUT warning: captured staged p1 with zero WSTRB at addr 0x410

- Root cause 2:
  - DUT/IF 在某些時刻（尤其是 reset 剛放、或 ready/valid 還沒完全初始化）很可能有一拍 arready 或 arvalid 不是乾淨的 1/0，而是 X
    - 在 @(posedge clk); #1; 才去看握手 —— 這會讓你很容易 錯過只在 clock edge 成立的一拍握手 
  - 你在這段裡是用 nonblocking assignment (<=) 去更新 staged_p1_wstrb_dma，但你立刻用
    if (staged_p1_wstrb_dma == '0) ...去檢查它。
    在 SystemVerilog 時序上，NBAs 會在 time slot 的 NBA region 才生效

- Fix 2
  - AW/W/B/AR/R interface 信號判定要更嚴謹, 改用`===`
  - Remove #1 delay, sample right away
  - 用 bridge 的來源訊號做 check 解決DUT warning

- Result 2:
  - Directed Test Case 3.2 PASSED
  - Monitor 沒再出現 R for unknown ID（之前最大的問題已解）
  - Case 3.2 的流程完整：
    - P0 full write @0x410 → P1 partial write @0x410 → P0 read / P1 read 都拿到同一個結果 0xaaaa334455667788
    - Scoreboard 最後 mismatches=0 且 FINAL RESULT: PASS
    - stats 也合理：
      - writes_p0=3（0x400 full + 0x400 partial + 0x410 full）
      - writes_p1=1（0x410 partial）
      - reads_p0=2（0x400,0x410）
      - reads_p1=1（0x410）
  - log
  ```
  # UVM_INFO @ 0:      [Questa UVM] QUESTA_UVM-1.2.3
  # UVM_INFO @ 0:      [Questa UVM]  questa_uvm::init(all)
  # UVM_INFO @ 0:      [RNTST] Running test axi_mm_directed_test...
  # UVM_INFO @ 0:      [AGENT] Building agent 'uvm_test_top.env_h.p0_agent' (ACTIVE)
  # UVM_INFO @ 0:      [AGENT] Building agent 'uvm_test_top.env_h.p1_agent' (ACTIVE)
  # UVM_INFO @ 0:      [ENV] axi_mm_env connected monitors to scoreboard
  # UVM_INFO @ 0:      [Questa UVM] End Of Elaboration
  # UVM_INFO @ 0:      [DIRECT_TEST] Case 3.2: Cross-port coherence (P0 full -> P1 partial -> read both)
  # UVM_INFO @ 0:      [SCB] Scoreboard started (STRICT_RANGE=0)
  # UVM_INFO @ 0:      [MON] AXI-MM Monitor started
  # UVM_INFO @ 55000:  [DRV] Driving WRITE addr=0x410 len=0 id=9
  # UVM_INFO @ 65000:  [MON] AW captured: ID=9 addr=0x410 len=0 burst=01 size=3
  # UVM_INFO @ 80000:  [DRV_DBG] W drive beat=0 data=0x1122334455667788 wstrb=0xff
  # UVM_INFO @ 85000:  [MON] W captured: ID=9 Beat=0 Addr=0x410 Data=0x1122334455667788 WLAST=1 burst=01 size=3
  # UVM_INFO @ 105000: [MON] WRITE completed: ID=9 Addr=0x410 Data[0]=0x1122334455667788 (Beats=1)
  # UVM_INFO @ 110000: [DRV] WRITE done: id=9 BRESP=0
  # UVM_INFO @ 110000: [uvm_sequence_item] DIRECTED WRITE addr=0x410 beats=1 id=0x9 burst=1 size=3
  # UVM_INFO @ 110000: [DRV] Driving WRITE addr=0x410 len=0 id=10
  # UVM_INFO @ 120000: [MON] AW captured: ID=10 addr=0x410 len=0 burst=01 size=3
  # UVM_INFO @ 144000: [DRV_DBG] W drive beat=0 data=0xaaaa000000000000 wstrb=0xc0
  # UVM_INFO @ 152000: [MON] W captured: ID=10 Beat=0 Addr=0x410 Data=0xaaaa000000000000 WLAST=1 burst=01 size=3
  # UVM_INFO @ 200000: [MON] WRITE completed: ID=10 Addr=0x410 Data[0]=0xaaaa000000000000 (Beats=1)
  # UVM_INFO @ 208000: [DRV] WRITE done: id=10 BRESP=0
  # UVM_INFO @ 208000: [uvm_sequence_item] DIRECTED WRITE addr=0x410 beats=1 id=0xa burst=1 size=3
  # UVM_INFO @ 208000: [DRV] Driving  READ addr=0x410 len=0 id=11
  # UVM_INFO @ 215000: [MON] AR captured: ID=11 addr=0x410 len=0 burst=01 size=3
  # UVM_INFO @ 245000: [MON] R captured: ID=11 Beat=0 Addr=0x410 Data=0xaaaa334455667788 RRESP=0 RLAST=1
  # UVM_INFO @ 250000: [DRV] READ done: id=11 beats=1 first=0xaaaa334455667788
  # UVM_INFO @ 250000: [uvm_sequence_item] DIRECTED  READ addr=0x410 beats=1 id=0xb burst=1 size=3
  # UVM_INFO @ 250000: [DRV] Driving  READ addr=0x410 len=0 id=12
  # UVM_INFO @ 264000: [MON] AR captured: ID=12 addr=0x410 len=0 burst=01 size=3
  # UVM_INFO @ 312000: [MON] R captured: ID=12 Beat=0 Addr=0x410 Data=0xaaaa334455667788 RRESP=0 RLAST=1
  # UVM_INFO @ 320000: [DRV] READ done: id=12 beats=1 first=0xaaaa334455667788
  # UVM_INFO @ 320000: [uvm_sequence_item] DIRECTED  READ addr=0x410 beats=1 id=0xc burst=1 size=3
  # UVM_INFO @ 320000: [DIRECT_TEST] Directed RAM test Case 3.2 completed @addr=0x410 (P0 full -> P1 partial -> read both)
  # UVM_INFO @ 320000: [TEST_DONE] 'run' phase is ready to proceed to the 'extract' phase
  # UVM_INFO @ 320000: [SCB] FINAL stats: writes_p0=1 writes_p1=1 reads_p0=1 reads_p1=1 mismatches=0
  # UVM_INFO @ 320000: [SCB] FINAL RESULT: PASS (no mismatches)
  ```

- Goal 3 (Case 3.3)
  - Write collision test
  - P0 and P1 both write the same address at the same time

- Expected Output 3:
  - address：例如 0x420（8B aligned）
  - P0 寫低 4 bytes（WSTRB=0x0F），data 放在低 4B
  - P1 寫高 4 bytes（WSTRB=0xF0），data 放在高 4B
  - 這兩筆 盡量同時 start
  - 然後：
  - P0 read @ same addr
  - P1 read @ same addr
  - 期望讀回：{P1_high4B, P0_low4B} 的 merge 結果

- Result 3:
  - Directed Test Case 3.3 PASSED
    - P0 write (WSTRB=0x0F)：只寫低 4 bytes，WDATA=0x00000000_1122_3344
    - P1 write (WSTRB=0xF0)：只寫高 4 bytes，WDATA=0xAABB_CCDD_0000_0000
    - 最後 P0 read / P1 read 都回來 0xAABB_CCDD_1122_3344
    - Scoreboard mismatches=0 / PASS
    - byte-enable merge 正確
    - dual-port coherence（兩個 port 對同一個 address 的寫入可被後續讀到一致結果）正確
    - monitor/driver/scoreboard 的基本資料流也正常（沒有 unknown ID、沒有漏 beat）
  - log
  ```
  # UVM_INFO @ 0:      [Questa UVM] QUESTA_UVM-1.2.3
  # UVM_INFO @ 0:      [Questa UVM]  questa_uvm::init(all)
  # UVM_INFO @ 0:      [RNTST] Running test axi_mm_directed_test...
  # UVM_INFO @ 0:      [AGENT] Building agent 'uvm_test_top.env_h.p0_agent' (ACTIVE)
  # UVM_INFO @ 0:      [MON] AXI-MM Monitor started
  # UVM_INFO @ 0:      [AGENT] Building agent 'uvm_test_top.env_h.p1_agent' (ACTIVE)
  # UVM_INFO @ 0:      [MON] AXI-MM Monitor started
  # UVM_INFO @ 0:      [ENV] axi_mm_env connected monitors to scoreboard
  # UVM_INFO @ 0:      [Questa UVM] End Of Elaboration
  # UVM_INFO @ 0:      [DIRECT_TEST] Case 3.3: Same-address cross-port collision + byte-merge
  # UVM_INFO @ 0:      [SCB] Scoreboard started (STRICT_RANGE=0)
  # UVM_INFO @ 55000:  [DRV] Driving WRITE addr=0x420 len=0 id=12
  # UVM_INFO @ 56000:  [DRV] Driving WRITE addr=0x420 len=0 id=13
  # UVM_INFO @ 65000:  [MON] AW captured: ID=12 addr=0x420 len=0 burst=01 size=3
  # UVM_INFO @ 72000:  [MON] AW captured: ID=13 addr=0x420 len=0 burst=01 size=3
  # UVM_INFO @ 80000:  [DRV_DBG] W drive beat=0 data=0x11223344 wstrb=0xf
  # UVM_INFO @ 85000:  [MON] W captured: ID=12 Beat=0 Addr=0x420 Data=0x0000000011223344 WLAST=1 burst=01 size=3
  # UVM_INFO @ 96000:  [DRV_DBG] W drive beat=0 data=0xaabbccdd00000000 wstrb=0xf0
  # UVM_INFO @ 104000: [MON] W captured: ID=13 Beat=0 Addr=0x420 Data=0xaabbccdd00000000 WLAST=1 burst=01 size=3
  # UVM_INFO @ 105000: [MON] WRITE completed: ID=12 Addr=0x420 Data[0]=0x0000000011223344 (Beats=1)
  # UVM_INFO @ 110000: [DRV] WRITE done: id=12 BRESP=0
  # UVM_INFO @ 110000: [uvm_sequence_item] DIRECTED WRITE addr=0x420 beats=1 id=0xc burst=1 size=3
  # UVM_INFO @ 152000: [MON] WRITE completed: ID=13 Addr=0x420 Data[0]=0xaabbccdd00000000 (Beats=1)
  # UVM_INFO @ 160000: [DRV] WRITE done: id=13 BRESP=0
  # UVM_INFO @ 160000: [uvm_sequence_item] DIRECTED WRITE addr=0x420 beats=1 id=0xd burst=1 size=3
  # UVM_INFO @ 160000: [DRV] Driving  READ addr=0x420 len=0 id=14
  # UVM_INFO @ 175000: [MON] AR captured: ID=14 addr=0x420 len=0 burst=01 size=3
  # UVM_INFO @ 205000: [MON] R captured: ID=14 Beat=0 Addr=0x420 Data=0xaabbccdd11223344 RRESP=0 RLAST=1
  # UVM_INFO @ 210000: [DRV] READ done: id=14 beats=1 first=0xaabbccdd11223344
  # UVM_INFO @ 210000: [uvm_sequence_item] DIRECTED  READ addr=0x420 beats=1 id=0xe burst=1 size=3
  # UVM_INFO @ 210000: [DRV] Driving  READ addr=0x420 len=0 id=15
  # UVM_INFO @ 232000: [MON] AR captured: ID=15 addr=0x420 len=0 burst=01 size=3
  # UVM_INFO @ 280000: [MON] R captured: ID=15 Beat=0 Addr=0x420 Data=0xaabbccdd11223344 RRESP=0 RLAST=1
  # UVM_INFO @ 288000: [DRV] READ done: id=15 beats=1 first=0xaabbccdd11223344
  # UVM_INFO @ 288000: [uvm_sequence_item] DIRECTED  READ addr=0x420 beats=1 id=0xf burst=1 size=3
  # UVM_INFO @ 288000: [DIRECT_TEST] Case 3.3 expected merged @0x420 = 0xaabbccdd11223344
  # UVM_INFO @ 288000: [DIRECT_TEST] Directed RAM test Case 3.3 completed @addr=0x420
  # UVM_INFO @ 288000: [TEST_DONE] 'run' phase is ready to proceed to the 'extract' phase
  # UVM_INFO @ 288000: [SCB] FINAL stats: writes_p0=1 writes_p1=1 reads_p0=1 reads_p1=1 mismatches=0
  # UVM_INFO @ 288000: [SCB] FINAL RESULT: PASS (no mismatches)
  ```

- Goal 4 (Case 4)
  -Burst 行為完整性 + 多 beat + WRAP/FIXED + 跨 port 一致性

- Objectives
  - Case 4.1：INCR burst 多 beat write + readback（同 port）
    - 4 beats（len=3），size=8B，burst=INCR
    - 寫完後用 read burst 回讀比對（scoreboard 自動比）

  - Case 4.2：WRAP burst 多 beat write + readback（同 port）
    - 4 beats WRAP（wrap_bytes=32）
    - start_addr 刻意放在 wrap region 的最後一個 beat offset，讓第 2 beat 真的 wrap 回 base
      - 這能驗證：DUT/monitor/scoreboard 的 wrap beat addr 計算一致

  - Case 4.3：FIXED burst（同 addr 重複寫多 beat）+ readback
    - FIXED burst 的每個 beat 都是同一個地址
    - 期望行為：最後一拍覆蓋前面（等價於「連續覆寫同一個 word」）read 回來應該看到 最後一拍的資料

  - Case 4.4：跨 port coherence（P0 寫 burst → P0/P1 都讀 burst）
    - P0 寫完後，P0 與 P1 同地址 burst read（可 fork 同時跑）
    - 期望兩邊都看到同樣資料序列

  - Write collision test
  - P0 and P1 both write the same address at the same time

- Expected Output 3:
  - address：例如 0x420（8B aligned）
  - P0 寫低 4 bytes（WSTRB=0x0F），data 放在低 4B
  - P1 寫高 4 bytes（WSTRB=0xF0），data 放在高 4B
  - 這兩筆 盡量同時 start
  - 然後：
  - P0 read @ same addr
  - P1 read @ same addr
  - 期望讀回：{P1_high4B, P0_low4B} 的 merge 結果


- Goal 5 (Case 5)
  - Same-port interleaving IDs（兩個 outstanding read / write）

- Objectives
  - Case 5.1：雙埠「同時」各自做長 burst 寫入 + 交叉 readback
    - P0：INCR burst 8 beats 寫到 case5_1_p0_addr
    - P1：INCR burst 8 beats 寫到 case5_1_p1_addr
    - 兩個 write 用 fork/join 同時打，測你 DUT 的雙埠橋接/CDC 與仲裁壓力
    - 寫完後，P0/P1 各自把自己的區域讀回來（也用 fork 同時讀）

  - Case 5.2：跨埠同地址「先 full burst，再 partial burst」的 byte-merge（跨多 beat）
    - P0：對 case5_2_addr 先做 full INCR burst 4 beats
    - P1：對同一個地址再做 partial INCR burst 4 beats（例如 WSTRB=0x0F 只改低 4 bytes）
    - 再由 P0、P1 各讀回 4 beats，比對 merge 後結果（由 scoreboard 模型處理）


## 日期
2026-01-27

- Goal 1: Case 5.1 & Case 5.2
  
- Issue 1:
  - Case 5.1 failed

- Root Cause:
  - DUT only spilled out 2 R beats, after that, rvalid stopped. So driver did not receive handshake -> R TIMEOUT
    - DUT 的 read FIFO count 更新有致命 bug：沒有處理「同一個 cycle 同時 push + pop」，造成 FIFO 計數被最後一個 <= 覆蓋，等效把「+1 與 -1」變成只剩「-1」，所以 FIFO 會被你自己“扣成空”，rvalid 很快變 0，後面 beats 就不會再出來

- Fix 1:
  - 把 FIFO push/pop 合併成一次更新（同一個 always_ff 裡只對 count 寫一次）
    - Port0 / Port1 的 Read FIFO：同一個 cycle push+pop 時，*_rd_count 只更新一次
    - 同時把 wptr/rptr/count 的更新用 push/pop 統一處理

- Result 1:
  - Timeout disappeared, Case 5.1 passed

- Result 2:
  - Case 5.2 passed

- Goal 2: Case 5.3
  - Design
    - P0/P1 start with same address
    - Same 8-beats INCR
    - WSTRB complement and interchange
      - P0: 8'hAA (1010_1010) -> Write lane 1, 3, 5, 7
      - P1: 8'h55 (0101_0101) -> Write lane 0, 2, 4, 6
    - Data pattern designed as byte recognizable
      - P0: 64'hA7A6A5A4A3A2A1A0
      - P1; 64'hB7B6B5B4B3B2B1B0
  - Expected Output
    - beat0 for example
      - P0 provides lanes 1, 3, 5, 7 => A1, A3, A5, A7
      - P1 provides ;anes 0, 2, 4, 6 => B0, B2, B4, B6
      - So final beat0 will be: 64'hA7B6A5B4A3B2A1B0
  
- Result 2
  - Case 5.3 PASSED
  ```
  # UVM_INFO @ 0:       [Questa UVM] QUESTA_UVM-1.2.3
  # UVM_INFO @ 0:       [Questa UVM] questa_uvm::init(all)
  # UVM_INFO @ 0:       [RNTST] Running test axi_mm_directed_test...
  # UVM_INFO @ 0:       [AGENT] Building agent 'uvm_test_top.env_h.p0_agent' (ACTIVE)
  # UVM_INFO @ 0:       [DRV_CFG] hold_bready_high=1 hold_rready_high=1 stress_enable=0 bready_prob=100 rready_prob=100 aw_pre_delay_max=0 ar_pre_delay_max=0 w_streaming_mode=0 w_beat_gap_max=0 force_ready_after=64 seed=0
  # UVM_INFO @ 0:       [VIF] vif(mp_monitor)=/axi_mm_top/dma_if
  # UVM_INFO @ 0:       [MON] AXI-MM Monitor started
  # UVM_INFO @ 0:       [AGENT] Building agent 'uvm_test_top.env_h.p1_agent' (ACTIVE)
  # UVM_INFO @ 0:       [DRV_CFG] hold_bready_high=1 hold_rready_high=1 stress_enable=0 bready_prob=100 rready_prob=100 aw_pre_delay_max=0 ar_pre_delay_max=0 w_streaming_mode=0 w_beat_gap_max=0 force_ready_after=64 seed=0
  # UVM_INFO @ 0:       [VIF] vif(mp_monitor)=/axi_mm_top/core_if
  # UVM_INFO @ 0:       [MON] AXI-MM Monitor started
  # UVM_INFO @ 0:       [ENV] axi_mm_env connected monitors to scoreboard
  # UVM_INFO @ 0:       [Questa UVM] End Of Elaboration
  # UVM_INFO @ 0:       [DIRECT_TEST] Case 5: Cross-port concurrency stress + multi-beat byte-merge
  # UVM_INFO @ 0:       [DIRECT_TEST] Case 5.3: Same-addr parallel INCR 8 beats + interleaved WSTRB (P0=AA, P1=55) @0x780
  # UVM_INFO @ 0:       [SCB] Scoreboard started (STRICT_RANGE=0)
  # UVM_INFO @ 65000:   [DRV] Driving WRITE addr=0x780 len=7 id=12
  # UVM_INFO @ 72000:   [DRV] Driving WRITE addr=0x780 len=7 id=13
  # UVM_INFO @ 85000:   [MON_AW_HS] AW HS: ID=12 addr=0x780 len=7 burst=01 size=3 (q_depth=1)
  # UVM_INFO @ 95001:   [DRV_DBG] W HS beat=0 data=0xa7a6a5a4a3a2a1a0 wstrb=0xaa last=0
  # UVM_INFO @ 104000:  [MON_AW_HS] AW HS: ID=13 addr=0x780 len=7 burst=01 size=3 (q_depth=1)
  # UVM_INFO @ 105000:  [MON_W_HS] W HS: head_id=12 beat=0/8 addr=0x780 data=0xa7a6a5a4a3a2a1a0 wstrb=0xaa wlast=0
  # UVM_INFO @ 120001:  [DRV_DBG] W HS beat=0 data=0xb7b6b5b4b3b2b1b0 wstrb=0x55 last=0
  # UVM_INFO @ 135000:  [MON_W_HS] W HS: head_id=12 beat=1/8 addr=0x788 data=0xa7a6a5a4a3a2a1a1 wstrb=0xaa wlast=0
  # UVM_INFO @ 135001:  [DRV_DBG] W HS beat=1 data=0xa7a6a5a4a3a2a1a1 wstrb=0xaa last=0
  # UVM_INFO @ 136000:  [MON_W_HS] W HS: head_id=13 beat=0/8 addr=0x780 data=0xb7b6b5b4b3b2b1b0 wstrb=0x55 wlast=0
  # UVM_INFO @ 165000:  [MON_W_HS] W HS: head_id=12 beat=2/8 addr=0x790 data=0xa7a6a5a4a3a2a1a2 wstrb=0xaa wlast=0
  # UVM_INFO @ 165001:  [DRV_DBG] W HS beat=2 data=0xa7a6a5a4a3a2a1a2 wstrb=0xaa last=0
  # UVM_INFO @ 195000:  [MON_W_HS] W HS: head_id=12 beat=3/8 addr=0x798 data=0xa7a6a5a4a3a2a1a3 wstrb=0xaa wlast=0
  # UVM_INFO @ 195001:  [DRV_DBG] W HS beat=3 data=0xa7a6a5a4a3a2a1a3 wstrb=0xaa last=0
  # UVM_INFO @ 225000:  [MON_W_HS] W HS: head_id=12 beat=4/8 addr=0x7a0 data=0xa7a6a5a4a3a2a1a4 wstrb=0xaa wlast=0
  # UVM_INFO @ 225001:  [DRV_DBG] W HS beat=4 data=0xa7a6a5a4a3a2a1a4 wstrb=0xaa last=0
  # UVM_INFO @ 232000:  [MON_W_HS] W HS: head_id=13 beat=1/8 addr=0x788 data=0xb7b6b5b4b3b2b1b1 wstrb=0x55 wlast=0
  # UVM_INFO @ 232001:  [DRV_DBG] W HS beat=1 data=0xb7b6b5b4b3b2b1b1 wstrb=0x55 last=0
  # UVM_INFO @ 255000:  [MON_W_HS] W HS: head_id=12 beat=5/8 addr=0x7a8 data=0xa7a6a5a4a3a2a1a5 wstrb=0xaa wlast=0
  # UVM_INFO @ 255001:  [DRV_DBG] W HS beat=5 data=0xa7a6a5a4a3a2a1a5 wstrb=0xaa last=0
  # UVM_INFO @ 285000:  [MON_W_HS] W HS: head_id=12 beat=6/8 addr=0x7b0 data=0xa7a6a5a4a3a2a1a6 wstrb=0xaa wlast=0
  # UVM_INFO @ 285001:  [DRV_DBG] W HS beat=6 data=0xa7a6a5a4a3a2a1a6 wstrb=0xaa last=0
  # UVM_INFO @ 315000:  [MON_W_HS] W HS: head_id=12 beat=7/8 addr=0x7b8 data=0xa7a6a5a4a3a2a1a7 wstrb=0xaa wlast=1
  # UVM_INFO @ 315001:  [DRV_DBG] W HS beat=7 data=0xa7a6a5a4a3a2a1a7 wstrb=0xaa last=1
  # UVM_INFO @ 328000:  [MON_W_HS] W HS: head_id=13 beat=2/8 addr=0x790 data=0xb7b6b5b4b3b2b1b2 wstrb=0x55 wlast=0
  # UVM_INFO @ 328001:  [DRV_DBG] W HS beat=2 data=0xb7b6b5b4b3b2b1b2 wstrb=0x55 last=0
  # UVM_INFO @ 335000:  [MON_WR_DONE] WRITE completed: ID=12 addr=0x780 beats=8 bresp=0
  # UVM_INFO @ 345000:  [DRV] WRITE done: id=12 BRESP=0 | 
  #                                       AW(addr=0x780 len=7 size=3 burst=01 id=12) | 
  #                                       B(bid=12 bresp=0)
  # UVM_INFO @ 345000:  [uvm_sequence_item] DIRECTED WRITE addr=0x780 beats=8 id=0xc burst=1 size=3
  # UVM_INFO @ 424000:  [MON_W_HS] W HS: head_id=13 beat=3/8 addr=0x798 data=0xb7b6b5b4b3b2b1b3 wstrb=0x55 wlast=0
  # UVM_INFO @ 424001:  [DRV_DBG] W HS beat=3 data=0xb7b6b5b4b3b2b1b3 wstrb=0x55 last=0
  # UVM_INFO @ 520000:  [MON_W_HS] W HS: head_id=13 beat=4/8 addr=0x7a0 data=0xb7b6b5b4b3b2b1b4 wstrb=0x55 wlast=0
  # UVM_INFO @ 520001:  [DRV_DBG] W HS beat=4 data=0xb7b6b5b4b3b2b1b4 wstrb=0x55 last=0
  # UVM_INFO @ 616000:  [MON_W_HS] W HS: head_id=13 beat=5/8 addr=0x7a8 data=0xb7b6b5b4b3b2b1b5 wstrb=0x55 wlast=0
  # UVM_INFO @ 616001:  [DRV_DBG] W HS beat=5 data=0xb7b6b5b4b3b2b1b5 wstrb=0x55 last=0
  # UVM_INFO @ 712000:  [MON_W_HS] W HS: head_id=13 beat=6/8 addr=0x7b0 data=0xb7b6b5b4b3b2b1b6 wstrb=0x55 wlast=0
  # UVM_INFO @ 712001:  [DRV_DBG] W HS beat=6 data=0xb7b6b5b4b3b2b1b6 wstrb=0x55 last=0
  # UVM_INFO @ 808000:  [MON_W_HS] W HS: head_id=13 beat=7/8 addr=0x7b8 data=0xb7b6b5b4b3b2b1b7 wstrb=0x55 wlast=1
  # UVM_INFO @ 808001:  [DRV_DBG] W HS beat=7 data=0xb7b6b5b4b3b2b1b7 wstrb=0x55 last=1
  # UVM_INFO @ 920000:  [MON_WR_DONE] WRITE completed: ID=13 addr=0x780 beats=8 bresp=0
  # UVM_INFO @ 936000:  [DRV] WRITE done: id=13 BRESP=0 | 
  #                                      AW(addr=0x780 len=7 size=3 burst=01 id=13) | 
  #                                      B(bid=13 bresp=0)
  # UVM_INFO @ 936000:  [uvm_sequence_item] DIRECTED WRITE addr=0x780 beats=8 id=0xd burst=1 size=3
  # UVM_INFO @ 986000:  [DRV] Driving  READ addr=0x780 len=7 id=15
  # UVM_INFO @ 986000:  [DRV] Driving  READ addr=0x780 len=7 id=14
  # UVM_INFO @ 1005000: [MON_AR_HS] AR HS: ID=14 addr=0x780 len=7 burst=01 size=3 (pending=1)
  # UVM_INFO @ 1016000: [MON_AR_HS] AR HS: ID=15 addr=0x780 len=7 burst=01 size=3 (pending=1)
  # UVM_INFO @ 1055000: [MON_R_HS] R HS: ID=14 beat=0/8 addr=0x780 data=0xa7b6a5b4a3b2a1b0 rresp=0 rlast=0
  # UVM_INFO @ 1065000: [MON_R_HS] R HS: ID=14 beat=1/8 addr=0x788 data=0xa7b6a5b4a3b2a1b1 rresp=0 rlast=0
  # UVM_INFO @ 1075000: [MON_R_HS] R HS: ID=14 beat=2/8 addr=0x790 data=0xa7b6a5b4a3b2a1b2 rresp=0 rlast=0
  # UVM_INFO @ 1085000: [MON_R_HS] R HS: ID=14 beat=3/8 addr=0x798 data=0xa7b6a5b4a3b2a1b3 rresp=0 rlast=0
  # UVM_INFO @ 1095000: [MON_R_HS] R HS: ID=14 beat=4/8 addr=0x7a0 data=0xa7b6a5b4a3b2a1b4 rresp=0 rlast=0
  # UVM_INFO @ 1096000:  [MON_R_HS] R HS: ID=15 beat=0/8 addr=0x780 data=0xa7b6a5b4a3b2a1b0 rresp=0 rlast=0
  # UVM_INFO @ 1105000:  [MON_R_HS] R HS: ID=14 beat=5/8 addr=0x7a8 data=0xa7b6a5b4a3b2a1b5 rresp=0 rlast=0
  # UVM_INFO @ 1112000:  [MON_R_HS] R HS: ID=15 beat=1/8 addr=0x788 data=0xa7b6a5b4a3b2a1b1 rresp=0 rlast=0
  # UVM_INFO @ 1115000:  [MON_R_HS] R HS: ID=14 beat=6/8 addr=0x7b0 data=0xa7b6a5b4a3b2a1b6 rresp=0 rlast=0
  # UVM_INFO @ 1125000:  [MON_R_HS] R HS: ID=14 beat=7/8 addr=0x7b8 data=0xa7b6a5b4a3b2a1b7 rresp=0 rlast=1
  # UVM_INFO @ 1128000:  [MON_R_HS] R HS: ID=15 beat=2/8 addr=0x790 data=0xa7b6a5b4a3b2a1b2 rresp=0 rlast=0
  # UVM_INFO @ 1135000:  [DRV] READ done: id=14 beats=8 first=0xa7b6a5b4a3b2a1b0 | 
  #                                       AR(addr=0x780 len=7 size=3 burst=01 id=14) | 
  #                                       R(last=1 rid=14)
  # UVM_INFO @ 1135000:  [uvm_sequence_item] DIRECTED  READ addr=0x780 beats=8 id=0xe burst=1 size=3
  # UVM_INFO @ 1144000:  [MON_R_HS] R HS: ID=15 beat=3/8 addr=0x798 data=0xa7b6a5b4a3b2a1b3 rresp=0 rlast=0
  # UVM_INFO @ 1160000:  [MON_R_HS] R HS: ID=15 beat=4/8 addr=0x7a0 data=0xa7b6a5b4a3b2a1b4 rresp=0 rlast=0
  # UVM_INFO @ 1176000:  [MON_R_HS] R HS: ID=15 beat=5/8 addr=0x7a8 data=0xa7b6a5b4a3b2a1b5 rresp=0 rlast=0
  # UVM_INFO @ 1192000:  [MON_R_HS] R HS: ID=15 beat=6/8 addr=0x7b0 data=0xa7b6a5b4a3b2a1b6 rresp=0 rlast=0
  # UVM_INFO @ 1208000:  [MON_R_HS] R HS: ID=15 beat=7/8 addr=0x7b8 data=0xa7b6a5b4a3b2a1b7 rresp=0 rlast=1
  # UVM_INFO @ 1224000:  [DRV] READ done: id=15 beats=8 first=0xa7b6a5b4a3b2a1b0 | 
  #                                       AR(addr=0x780 len=7 size=3 burst=01 id=15) | 
  #                                       R(last=1 rid=15)
  # UVM_INFO @ 1224000:  [uvm_sequence_item] DIRECTED  READ addr=0x780 beats=8 id=0xf burst=1 size=3
  # UVM_INFO @ 1224000:  [DIRECT_TEST] Directed RAM test Case 5 completed
  # UVM_INFO @ 1224000:  [TEST_DONE] 'run' phase is ready to proceed to the 'extract' phase
  # UVM_INFO @ 1224000:  [SCB] FINAL stats: writes_p0=1 writes_p1=1 reads_p0=1 reads_p1=1 mismatches=0
  # UVM_INFO @ 1224000:  [SCB] FINAL RESULT: PASS (no mismatches)
  ```


## 日期
2026-01-28

- Goal
  - Start Random Test
    - 10 Test Cases
      - Case 1: Basic Random Smoke / Sanity
        - Configuration
          - Single port (P0 only)
          - Low transaction count (≈100–500)
          - No stress, no backpressure
          - FIXED / INCR bursts
          - Small burst length (len ≤ 7)
          - Fixed data size (8B)
          - Full WSTRB (all bytes enabled)
        - Purpose
          - Validate random sequence infrastructure
          - Ensure driver / monitor / scoreboard stability
          - Catch trivial integration or modeling errors early

      - Case 2: Single-Port Ready Backpressure Stress
        - Configuration
          - Single port (P0 only)
          - Driver stress enabled
          - Randomized bready / rready (≈60–80%)
          - w_streaming_mode=1
          - Small address delays and beat gaps
        - Purpose
          - Small address delays and beat gaps
          - Stress driver handling of backpressure
          - Validate response ordering under stalls

     - Case 3: Dual-Port Independent Random Traffic
        - Configuration
         - Dual port (P0 & P1 concurrent)
         - Separate, non-overlapping address regions
         - Moderate transaction count
         - Low conflict by construction
        - Purpose
         -  Validate basic dual-port concurrency
         -  Ensure independence of P0 and P1 channels
         -  Confirm no cross-port interference under normal conditions

     - Case 4: Dual-Port High-Conflict Random (Shared Window)
        - Configuration
         - Dual port active
         - Both ports restricted to a small shared address window (e.g., 256B–512B)
         - Mixed reads and writes
        - Purpose
         -  Stress address collisions and near-address hazards
         -  Verify last-writer-wins semantics
         -  Validate scoreboard consistency under write conflicts

     - Case 5: Mixed Burst Types (INCR / FIXED)
        - Configuration
          - Dual port
          - Randomized burst types (INCR + FIXED)
          - Moderate stress and interleaving
        - Purpose
          -  Validate burst decoding and address progression logic
          -  Ensure FIXED bursts behave correctly under contention

     - Case 6: Wrap Burst Random (No Window Split)
        - Configuration
          - Dual port
          - WRAP bursts enabled
          - Power-of-two wrap sizes
          - Moderate wrap probability
        - Purpose
          -  Validate wrap address calculation
          -  Catch wrap boundary and modulo errors
          -  Ensure scoreboard wrap modeling matches DUT behavior

     - Case 7: Window-Restricted Random (Split Windows)
        - Configuration
          - Dual port
          - Each port constrained to its own address window
          - Mixed reads/writes, moderate stress
        - Purpose
          -  Validate address window enforcement
          -  Prepare infrastructure for split-window operation
          -  Ensure no leakage outside configured regions
    
     - Case 8: Wrap Burst with Split Windows (Foldback Focus)
        - Configuration
          - Dual port, split windows
          - High WRAP probability
          - Enabled address locality
          - Increasing backpressure and beat gaps
        - Purpose
          -  Stress WRAP foldback behavior near window boundaries
          -  Validate corner wrap + window interactions
          -  Catch off-by-one and boundary-crossing bugs
  
     - Case 9: Size-Randomized Mixed Traffic
        - Configuration
          - Dual port, split windows
          - Randomized AXI sizes (1B / 2B / 4B / 8B)
          - Mixed reads and writes
          - Moderate-to-high transaction count
        - Purpose
          -  Validate size-dependent address stepping
          -  Stress scoreboard data slicing and alignment logic
          -  Ensure correct behavior across all legal AXI sizes

     - Case 10: Partial WSTRB Stress (Write-Heavy)
        - Configuration
          - Dual port, split windows
          - Partial write enabled with randomized byte masks
          - Write-heavy traffic mix
          - Moderate-to-high stress (backpressure, gaps, interleaving)
        - Purpose
          -  Thoroughly validate byte-lane merge semantics
          -  Stress scoreboard WSTRB masking model
          -  Confirm correctness under dense partial-write traffic

## 日期
2026-01-31

- Random Test Journey: Issues Encountered & Resolutions (R1–R10)
R1 – Initial Random Bring-Up

Issue

Early uncertainty whether random flow, driver, monitor, and scoreboard were correctly wired.

Risk of “false pass” due to insufficient activity or coverage.

Resolution

Started with low-stress, simple bursts (INCR/FIXED, aligned, full WSTRB).

Confirmed end-to-end data integrity and stable scoreboard behavior.

Established a known-good random baseline.

R2 – Backpressure & Ready/Valid Stress

Issue

Potential deadlocks or dropped handshakes under randomized READY.

Concern about driver robustness when READY toggles aggressively.

Resolution

Added controlled driver stress knobs (bready_prob, rready_prob, pre-delay).

Introduced force_ready_after safeguard to prevent infinite stalls.

Verified no deadlock, no lost beats.

R3 – Dual-Port Concurrency

Issue

Risk of interference between P0 and P1 when running concurrently.

Needed to distinguish DUT bugs vs. scoreboard modeling errors.

Resolution

Ran dual ports with separate address windows (low conflict).

Validated independent progress, ordering, and completion on both ports.

Confirmed scoreboard correctly tracks per-port transactions.

R4 – High Address Conflict

Issue

Heavy overwrite scenarios exposed potential scoreboard mismatches.

Needed clarity on “last writer wins” semantics.

Resolution

Constrained both ports into a small shared window.

Explicitly aligned scoreboard model with DUT overwrite rules.

Validated deterministic behavior under write collisions.

R5 – Read/Write Interleaving Hazards

Issue

RAW/WAR ordering corner cases when reads follow writes closely.

Risk of false mismatches if scoreboard timing assumptions were wrong.

Resolution

Added locality control to cluster accesses near recent addresses.

Ensured scoreboard updates occur on correct protocol events (W/B completion).

Confirmed read data always matches architectural expectations.

R6 – Long Bursts & Sustained Traffic

Issue

Concern about FIFO depth, burst accounting, and internal counters under load.

Potential for rare bugs only visible after thousands of transactions.

Resolution

Increased transaction count and burst lengths.

Verified no overflow, no ordering corruption, no scoreboard drift.

Built confidence in long-run stability.

R7 – Address Window + Memory Clamp Interaction

Issue

Early versions risked generating addresses outside BRAM range when windowing.

Bugs were subtle and seed-dependent.

Resolution

Enforced restrict_to_mem + mem_bytes unconditionally.

Made memory clamp orthogonal to windowing.

Eliminated runaway address generation entirely.

R8 – WRAP Burst Correctness (Split Window)

Issue

WRAP bursts are easy to get “mostly right” but wrong at boundaries.

Foldback behavior at wrap boundary was a high-risk area.

Resolution

Progressed in stages:

R8a: foldback-focused, low stress

R8b: foldback + timing stress

R8: full mix (high wrap %, backpressure, locality)

Verified correct address folding and scoreboard wrap tracking.

Multiple seeds passed → high confidence WRAP correctness.

R9 – SIZE Randomization

Issue

Variable size (1B/2B/4B/8B) greatly increases modeling complexity.

Risk of misaligned accesses and incorrect byte-lane handling.

Resolution

Enabled enable_size_rand with controlled constraints.

Ensured address alignment logic and scoreboard byte math were correct.

Confirmed mixed sizes + wrap + split windows behave correctly.

R10 – Partial WSTRB Stress

Issue

Partial writes are the hardest correctness dimension:

Byte-mask merge

Read-after-partial-write correctness

Needed confidence that partial logic wasn’t accidentally masked by full writes.

Resolution

Added explicit partial_prob control.

Made test write-heavy and kept size fixed to limit combinatorial explosion.

Observed diverse WSTRB patterns across bursts and wraps.

Scoreboard showed zero mismatches across many seeds → strong validation.


## 日期
2026-02-01

- Goal: Start on Corner test
- Total 10 cases:
- Case C1 – Zero-Length & Single-Beat Bursts

Focus

AXI LEN=0 (single beat) and minimal burst behavior

Key Checks

WLAST / RLAST assertion

LEN vs actual beat count consistency

Scoreboard off-by-one correctness

Why First

Most deterministic, lowest noise

Immediately exposes fundamental protocol bookkeeping bugs

Case C2 – Partial WSTRB Extremes

Focus

Byte-enable edge cases

Stimulus

WSTRB = all-0 (no byte update)

WSTRB = all-1 (full overwrite)

Optional: single-bit / sparse masks

Key Checks

Memory merge semantics

“No unintended write” on all-zero mask

Why Early

Core correctness of BRAM + scoreboard byte model

Case C3 – FIXED Burst Corner Behavior

Focus

BURST=FIXED, multi-beat transactions

Key Checks

Address must remain constant across beats

Monitor / scoreboard address expansion correctness

Why Here

Isolates FIXED semantics before mixing with WRAP or heavy stress

Case C4 – WRAP Burst: Exact Boundary

Focus

WRAP burst starting exactly on wrap boundary

Key Checks

Correct wrap window size

Clean foldback to base address

Why Before Off-by-One

Establishes a “golden” WRAP reference behavior

Case C5 – WRAP Burst: Off-by-One Foldback

Focus

WRAP bursts starting near (but not exactly on) boundary

Key Checks

Tail-end foldback correctness

No address drift or mis-expansion

Why After C4

Builds on verified exact-boundary behavior

Case C6 – Window Edge Crossing

Focus

INCR bursts crossing split-window boundaries

Stimulus

Bursts starting near window_end - N

Key Checks

Address clamping correctness

No illegal address generation

Why Mid-Sequence

Depends on correct INCR + window logic

Case C7 – Maximum-Length Bursts

Focus

Longest supported burst lengths

Key Checks

FIFO depth assumptions

Monitor / scoreboard queue robustness

Why Later

Avoids burying basic bugs under long traces

Case C8 – AW / AR Channel Contention

Focus

Simultaneous and interleaved AW/AR issuance

Stimulus

Read/write overlap

Independent backpressure

Key Checks

Channel decoupling

No deadlock or lost transactions

Case C9 – ID Ordering Corner Cases

Focus

AXI ID ordering rules

Stimulus

Back-to-back transactions with same ID

Interleaved transactions with different IDs

Key Checks

In-order completion per ID

Correct scoreboard association

Why Late

High log noise, best tested after protocol basics are proven

Case C10 – Reset / Flush During Activity

Focus

Reset or flush with outstanding transactions

Key Checks

Defined reset semantics

Scoreboard/model recovery behavior

Why Last

Most disruptive

Requires all prior invariants to be trusted


- Objective 1: Case 1:
  - Result 1: Case 1 PASSED
  - log:
  ```
  # UVM_INFO @ 0:       [Questa UVM] QUESTA_UVM-1.2.3
  # UVM_INFO @ 0:       [Questa UVM]  questa_uvm::init(all)
  # UVM_INFO @ 0:       [RNTST] Running test axi_mm_corner_test...
  # UVM_INFO @ 0:       [AGENT] Building agent 'uvm_test_top.env_h.p0_agent' ( ACTIVE)
  # UVM_INFO @ 0:       [DRV_CFG] hold_bready_high=1 hold_rready_high=1 stress_enable=0 bready_prob=100 rready_prob=100 aw_pre_delay_max=0 ar_pre_delay_max=0 w_streaming_mode=0 w_beat_gap_max=0 force_ready_after=64 seed=0
  # UVM_INFO @ 0:       [VIF] vif(mp_monitor)=/axi_mm_top/dma_if
  # UVM_INFO @ 0:       [MON] AXI-MM Monitor started
  # UVM_INFO @ 0:       [AGENT] Building agent 'uvm_test_top.env_h.p1_agent' (ACTIVE)
  # UVM_INFO @ 0:       [DRV_CFG] hold_bready_high=1 hold_rready_high=1 stress_enable=0 bready_prob=100 rready_prob=100 aw_pre_delay_max=0 ar_pre_delay_max=0 w_streaming_mode=0 w_beat_gap_max=0 force_ready_after=64 seed=0
  # UVM_INFO @ 0:       [VIF] vif(mp_monitor)=/axi_mm_top/core_if
  # UVM_INFO @ 0:       [MON] AXI-MM Monitor started
  # UVM_INFO @ 0:       [ENV] axi_mm_env connected monitors to scoreboard
  # UVM_INFO @ 0:       [Questa UVM] End Of Elaboration
  # UVM_INFO @ 0:       [CORNER_TEST] Starting AXI-MM corner-case transaction test
  # UVM_INFO @ 0:       [CORNER_TEST] [CASE_1] Start: LEN=0 single-beat READ/WRITE (INCR/FIXED) + WSTRB(FF/00/partial). a0=0x0 a1=0x1080
  # UVM_INFO @ 0:       [SCB] Scoreboard started (STRICT_RANGE=0)
  # UVM_INFO @ 65000:   [DRV] Driving WRITE addr=0x0 len=0 id=1
  # UVM_INFO @ 72000:   [DRV] Driving WRITE addr=0x1080 len=0 id=5
  # UVM_INFO @ 85000:   [MON_AW_HS] AW HS: ID=1 addr=0x0 len=0 burst=01 size=3 (q_depth=1)
  # UVM_INFO @ 95001:   [DRV_DBG] W HS beat=0 data=0xc1c1000000000001 wstrb=0xff last=1
  # UVM_INFO @ 104000:  [MON_AW_HS] AW HS: ID=5 addr=0x1080 len=0 burst=01 size=3 (q_depth=1)
  # UVM_INFO @ 105000:  [MON_W_HS] W HS: head_id=1 beat=0/1 addr=0x0 data=0xc1c1000000000001 wstrb=0xff wlast=1
  # UVM_INFO @ 120001:  [DRV_DBG] W HS beat=0 data=0xc1c1000000001001 wstrb=0xff last=1
  # UVM_INFO @ 125000:  [MON_WR_DONE] WRITE completed: ID=1 addr=0x0 beats=1 bresp=0
  # UVM_INFO @ 135000:  [DRV] WRITE done: id=1 BRESP=0 | 
  #                                       AW(addr=0x0 len=0 size=3 burst=01 id=1) |  
  #                                       B(bid=1 bresp=0)
  # UVM_INFO @ 135000:  [DRV] Driving  READ addr=0x0 len=0 id=2
  # UVM_INFO @ 136000:  [MON_W_HS] W HS: head_id=5 beat=0/1 addr=0x1080 data=0xc1c1000000001001 wstrb=0xff wlast=1
  # UVM_INFO @ 155000:  [MON_AR_HS] AR HS: ID=2 addr=0x0 len=0 burst=01 size=3 (pending=1)
  # UVM_INFO @ 205000:  [MON_R_HS] R HS: ID=2 beat=0/1 addr=0x0 data=0xc1c1000000000001 rresp=0 rlast=1
  # UVM_INFO @ 215000:  [DRV] READ done: id=2 beats=1 first=0xc1c1000000000001 | 
  #                                      AR(addr=0x0 len=0 size=3 burst=01 id=2) | 
  #                                      R(last=1 rid=2)
  # UVM_INFO @ 215000:  [DRV] Driving WRITE addr=0x20 len=0 id=3
  # UVM_INFO @ 235000:  [MON_AW_HS] AW HS: ID=3 addr=0x20 len=0 burst=00 size=3 (q_depth=1)
  # UVM_INFO @ 245001:  [DRV_DBG] W HS beat=0 data=0xc1c1000000000003 wstrb=0xff last=1
  # UVM_INFO @ 248000:  [MON_WR_DONE] WRITE completed: ID=5 addr=0x1080 beats=1 bresp=0
  # UVM_INFO @ 255000:  [MON_W_HS] W HS: head_id=3 beat=0/1 addr=0x20 data=0xc1c1000000000003 wstrb=0xff wlast=1
  # UVM_INFO @ 264000:  [DRV] WRITE done: id=5 BRESP=0 | 
  #                                       AW(addr=0x1080 len=0 size=3 burst=01 id=5) | 
  #                                       B(bid=5 bresp=0)
  # UVM_INFO @ 264000:  [DRV] Driving  READ addr=0x1080 len=0 id=6
  # UVM_INFO @ 275000:  [MON_WR_DONE] WRITE completed: ID=3 addr=0x20 beats=1 bresp=0
  # UVM_INFO @ 285000:  [DRV] WRITE done: id=3 BRESP=0 | 
  #                                       AW(addr=0x20 len=0 size=3 burst=00 id=3) | 
  #                                       B(bid=3 bresp=0)
  # UVM_INFO @ 285000:  [DRV] Driving  READ addr=0x20 len=0 id=4
  # UVM_INFO @ 296000:  [MON_AR_HS] AR HS: ID=6 addr=0x1080 len=0 burst=01 size=3 (pending=1)
  # UVM_INFO @ 305000:  [MON_AR_HS] AR HS: ID=4 addr=0x20 len=0 burst=00 size=3 (pending=1)
  # UVM_INFO @ 355000:  [MON_R_HS] R HS: ID=4 beat=0/1 addr=0x20 data=0xc1c1000000000003 rresp=0 rlast=1
  # UVM_INFO @ 365000:  [DRV] READ done: id=4 beats=1 first=0xc1c1000000000003 | 
  #                                      AR(addr=0x20 len=0 size=3 burst=00 id=4) | 
  #                                      R(last=1 rid=4)
  # UVM_INFO @ 365000:  [DRV] Driving WRITE addr=0x60 len=0 id=10
  # UVM_INFO @ 376000:  [MON_R_HS] R HS: ID=6 beat=0/1 addr=0x1080 data=0xc1c1000000001001 rresp=0 rlast=1
  # UVM_INFO @ 385000:  [MON_AW_HS] AW HS: ID=10 addr=0x60 len=0 burst=01 size=3 (q_depth=1)
  # UVM_INFO @ 392000:  [DRV] READ done: id=6 beats=1 first=0xc1c1000000001001 | 
  #                                      AR(addr=0x1080 len=0 size=3 burst=01 id=6) | 
  #                                      R(last=1 rid=6)
  # UVM_INFO @ 392000:  [DRV] Driving WRITE addr=0x10c0 len=0 id=7
  # UVM_INFO @ 395001:  [DRV_DBG] W HS beat=0 data=0xaaaabbbbccccdddd wstrb=0xff last=1
  # UVM_INFO @ 405000:  [MON_W_HS] W HS: head_id=10 beat=0/1 addr=0x60 data=0xaaaabbbbccccdddd wstrb=0xff wlast=1
  # UVM_INFO @ 424000:  [MON_AW_HS] AW HS: ID=7 addr=0x10c0 len=0 burst=01 size=3 (q_depth=1)
  # UVM_INFO @ 425000:  [MON_WR_DONE] WRITE completed: ID=10 addr=0x60 beats=1 bresp=0
  # UVM_INFO @ 435000:  [DRV] WRITE done: id=10 BRESP=0 |  
  #                                       AW(addr=0x60 len=0 size=3 burst=01 id=10) | 
  #                                       B(bid=10 bresp=0)
  # UVM_INFO @ 435000:  [DRV] Driving WRITE addr=0x60 len=0 id=11
  # UVM_INFO @ 440001:  [DRV_DBG] W HS beat=0 data=0x1111222233334444 wstrb=0xff last=1
  # UVM_INFO @ 455000:  [MON_AW_HS] AW HS: ID=11 addr=0x60 len=0 burst=01 size=3 (q_depth=1)
  # UVM_INFO @ 456000:  [MON_W_HS] W HS: head_id=7 beat=0/1 addr=0x10c0 data=0x1111222233334444 wstrb=0xff wlast=1
  # UVM_INFO @ 465001:  [DRV_DBG] W HS beat=0 data=0x1111222233334444 wstrb=0xf last=1
  # UVM_INFO @ 475000:  [MON_W_HS] W HS: head_id=11 beat=0/1 addr=0x60 data=0x1111222233334444 wstrb=0xf wlast=1
  # UVM_INFO @ 495000:  [MON_WR_DONE] WRITE completed: ID=11 addr=0x60 beats=1 bresp=0
  # UVM_INFO @ 505000:  [DRV] WRITE done: id=11 BRESP=0 | 
  #                                       AW(addr=0x60 len=0 size=3 burst=01 id=11) | 
  #                                       B(bid=11 bresp=0)
  # UVM_INFO @ 505000:  [DRV] Driving  READ addr=0x60 len=0 id=12
  # UVM_INFO @ 525000:  [MON_AR_HS] AR HS: ID=12 addr=0x60 len=0 burst=01 size=3 (pending=1)
  # UVM_INFO @ 568000:  [MON_WR_DONE] WRITE completed: ID=7 addr=0x10c0 beats=1 bresp=0
  # UVM_INFO @ 575000:  [MON_R_HS] R HS: ID=12 beat=0/1 addr=0x60 data=0xaaaabbbb33334444 rresp=0 rlast=1
  # UVM_INFO @ 584000:  [DRV] WRITE done: id=7 BRESP=0 | 
  #                                       AW(addr=0x10c0 len=0 size=3 burst=01 id=7) | 
  #                                       B(bid=7 bresp=0)
  # UVM_INFO @ 584000:  [DRV] Driving WRITE addr=0x10c0 len=0 id=8
  # UVM_INFO @ 585000:  [DRV] READ done: id=12 beats=1 first=0xaaaabbbb33334444 | 
  #                                      AR(addr=0x60 len=0 size=3 burst=01 id=12) | 
  #                                      R(last=1 rid=12)
  # UVM_INFO @ 616000:  [MON_AW_HS] AW HS: ID=8 addr=0x10c0 len=0 burst=01 size=3 (q_depth=1)
  # UVM_INFO @ 632001:  [DRV_DBG] W HS beat=0 data=0xdeadbeefdeadbeef wstrb=0x0 last=1
  # UVM_INFO @ 648000:  [MON_W_HS] W HS: head_id=8 beat=0/1 addr=0x10c0 data=0xdeadbeefdeadbeef wstrb=0x0 wlast=1
  # UVM_INFO @ 760000:  [MON_WR_DONE] WRITE completed: ID=8 addr=0x10c0 beats=1 bresp=0
  # UVM_INFO @ 776000:  [DRV] WRITE done: id=8 BRESP=0 | 
  #                                       AW(addr=0x10c0 len=0 size=3 burst=01 id=8) | 
  #                                       B(bid=8 bresp=0)
  # UVM_INFO @ 776000:  [DRV] Driving  READ addr=0x10c0 len=0 id=9
  # UVM_INFO @ 808000:  [MON_AR_HS] AR HS: ID=9 addr=0x10c0 len=0 burst=01 size=3 (pending=1)
  # UVM_INFO @ 888000:  [MON_R_HS] R HS: ID=9 beat=0/1 addr=0x10c0 data=0x1111222233334444 rresp=0 rlast=1
  # UVM_INFO @ 904000:  [DRV] READ done: id=9 beats=1 first=0x1111222233334444 | 
  #                                      AR(addr=0x10c0 len=0 size=3 burst=01 id=9) | 
  #                                      R(last=1 rid=9)
  # UVM_INFO @ 1104000: [CORNER_TEST] [CASE_1] Done.
  # UVM_INFO @ 1104000: [CORNER_TEST] Corner-case transaction test completed
  # UVM_INFO @ 1104000: [TEST_DONE] 'run' phase is ready to proceed to the 'extract' phase
  # UVM_INFO @ 1104000: [SCB] FINAL stats: writes_p0=4 writes_p1=3 reads_p0=3 reads_p1=2 mismatches=0
  # UVM_INFO @ 1104000: [SCB] FINAL RESULT: PASS (no mismatches)
  ```

## 日期
2026-02-16

- Faced Issue
  - run.tcl無法編譯
  ```
  # ** Error: (vopt-13130) Failed to find design unit . 
  # Searched libraries: 
  # work 
  # Optimization failed 
  # Error loading design
  ```
  - 原因
    - 我的 \ 後面有空白
  - 解釋
    - 如果tcl要換行, 確保 \ 是該行「最後一個字元」, \ 後面不能有任何空白

## 日期
2026-02-23

- Corner Test PASSED
  - Case 1: Zero-length & Single-beat bursts (LEN=0 => 1 beat) + WSTRB corner

Configuration

Dual port (P0 & P1)

Burst: INCR + FIXED（WRAP 不含在此 case）

Size=8B（3’d3），LEN=0（single beat）

Ready always-high、stress off（deterministic）

WSTRB 覆蓋：FF（full）、00（no-op）、以及 partial（例如 0x0F）

Purpose

驗證最基本的 READ/WRITE single-beat correctness

驗證 FIXED/INCR 單拍行為

驗證 scoreboard 對 WSTRB=0（必須不改變記憶體） 與 partial merge 的建模正確

Case 2: Boundary crossing at window edge + end-of-memory edge

Configuration

Dual port (P0 & P1)

P0: INCR burst 強制跨 4KB window boundary（0x0FFF → 0x1000）

2-beat crossing (start 0x0FF8)

4-beat crossing (start 0x0FE8)

P1: single beat access at last valid beat address（0x1FF8）

stress off、ready always-high（deterministic）

Purpose

驗證 window boundary crossing 的 address / memory mapping

驗證 end-of-memory 最後一拍 address 的合法行為與 scoreboard 對應

Case 3: Ordering + cross-port overwrite + partial merge (deterministic)

Configuration

Dual port：刻意用 共享 address A_shared

P1 先做 FULL write，P0 再做 PARTIAL write（per-byte merge by WSTRB）

P0 額外加同 ID ordering sanity（同一個 ID 寫兩筆，再讀回）

stress off、ready always-high；用延遲確保順序 deterministic

Purpose

驗證 cross-port 同址覆寫時的 last-writer / per-byte merge 規則

驗證同 ID ordering 的 scoreboard/driver tracking 沒問題

Case 4: AW/AR contention overlap + verified burst read (forced overlap)

Configuration

Phase A: PRIME（先寫好 read target）

Phase B: P0 發 long-ish write burst，同時 P1 early inject AR（強制 AW/AR overlap）

Dual port concurrent

Purpose

驗證 AW/AR contention 下 driver/monitor/scoreboard 不會亂或 deadlock

驗證 contention 後 readback 仍正確

Case 5: WRAP(4-beat) edge cases + FIXED burst last-wins

Configuration

WRAP burst: len=3（4 beats）, size=8B → wrap boundary=32B

exact-boundary start（32B 對齊）

off-by-one style start（base+24B，強制 wrap 回 base）

FIXED burst: len=3（4 beats）同址連打，最後 single-beat read 驗證 last beat wins

Dual port：P0 做 WRAP + FIXED；P1 做 WRAP

Purpose

驗證 WRAP addressing 正確（boundary / off-by-one）

驗證 FIXED burst 的 last-beat-wins 行為正確

Case 6: WRAP(8-beat) edge cases (64B boundary)

Configuration

WRAP burst: len=7（8 beats）, size=8B → wrap boundary=64B

起點選 base+0x38 與 base+0x30，強迫 wrap 發生在不同 beat

Dual port concurrent，每個 WRAP write 後都做 WRAP read verify

Purpose

更完整覆蓋 WRAP 8-beat 的 wrap address pattern

驗證 scoreboard 對 wrapped beat-by-beat address mapping 正確

Case 7: Partial WSTRB patterns (00/FF/0F/F0/AA/55) single-beat

Configuration

Dual port，各自單拍 len=0，不同 WSTRB pattern

流程：seed full write → read → WSTRB=00 no-op → read → partials → reads

stress off、ready always-high

Purpose

系統性驗證 byte-enable merge 規則（含 no-op、半邊、高低、交錯）

確認 scoreboard 對 WSTRB 模型完全一致

Case 8: Outstanding AW depth4 + observable stall (bonus ordering, dual-port)

Configuration

Dual port concurrent

目標：讓 AW backpressure/stall 在 log 可見

手法：AW(A/B/C) 先塞滿 → W(A) 先送讓 DUT 產生 B → 再送 AW(D)（預期 stall）→ 再補完 W(B/C/D) → B_WAIT reverse → readback

Purpose

驗證 outstanding AW credit/backpressure 的行為可觀察、可推導

驗證 driver 在「AW 被卡住時」仍可由背景 B collector 釋放 credit（避免死結）

Case 8.1 (8A): Depth1-friendly split AW/W (single-port)

Configuration

Single port (P0)

同一 port 做兩個 write：每筆拆成 AW_ONLY → W_ONLY

之後用 B_WAIT 等 response（可 permute），再 readback verify

Purpose

支援 DUT 只有 depth=1（或較嚴格時序）也能測到 multi-AW 情境

驗證 split-transaction（AW/W 分離）driver/scoreboard tracking 正確

Case 8.2 (8B): Outstanding writes + out-of-order B_WAIT (dual-port)

Configuration

Dual port concurrent

每個 port：AW_ONLY(A,B) → W_ONLY(A,B) → B_WAIT(B) 再 B_WAIT(A)（反序）→ readback

Purpose

驗證 testbench 以 BID gating 完成（而不是 FIFO order 假設）

驗證多 port 同時 outstanding 的 tracking 不互相污染

Case 9.1 (9A): Mixed-ID ordering stress (single-port P0)

Configuration

Single port (P0)

3 笔不同 ID 的 write（AW_ONLY 先塞）→ W_ONLY 全送 → B_WAIT 用 permuted order（非 1→2→3）→ readback

Purpose

驗證 scoreboard/driver 的完成判定是「依 ID」而非 FIFO

驗證 mixed-ID 下的 completion bookkeeping 穩定

Case 9.2 (9B): Mixed-ID ordering concurrent (P0/P1)

Configuration

Dual port concurrent

每 port 3 个不同 ID；B_WAIT order 不同（P0: 2→1→3，P1: 3→1→2）

最後 readback verify（用不同 read IDs）

Purpose

驗證在 multi-port concurrency 下，ID-based completion tracking 仍正確

驗證 TB 對 multi-ID、多 port 的 bookkeeping 沒 race

Case 10: Reset / Flush During Activity (stable)

Configuration

Dual port

Phase A: 大量 in-flight traffic（不 verify）

Mid-flight: assert reset（當 flush 用），不 stop_sequences、不 seq.stop

Phase B: reset 後重新做少量乾淨 traffic 並 verify

Purpose

驗證 reset/flush during activity 時 driver 能自動 abort/回到 idle

驗證 reset 後 DUT/TB 進入乾淨狀態，後續 transaction 可正確 PASS

Case 11: MAX legal burst length (LEN=255 => 256 beats) within window

Configuration

Dual port

INCR write/read

LEN=255（256 beats），size=8B

地址選在 window 內部（避免 crossing，讓 check 乾淨）

Purpose

驗證最大 burst length 的 driver/monitor/scoreboard buffer 能力

驗證長 burst 下 address increment、beat counting、R/W beat 對齊

Case 12: Narrow transfer sizes + lane mapping + brutal overlaps (Method A)

Configuration

Dual port

base address 固定 beat-aligned（AWADDR 對齊）

size 覆蓋：1B/2B/4B/8B（size=0/1/2/3）

lane selection 主要用 WSTRB 控制

加入多段「brutal overlap chain」：不同 size 在同一 beat 重疊覆寫，再 readback

Purpose

驗證 narrow size（byte/halfword/word）對 lane mapping 的正確性

驗證多次 partial overlap 的 merge priority 與 scoreboard modeling 正確

強化 corner：同一 byte lane 被不同 size 多次覆寫

Case 13: READY backpressure + (optional) stress

Configuration

Dual port small mixed traffic（write/read/burst、含 FIXED/INCR）

driver 允許 READY wiggle（cfg_driver_hold_ready(0,0)）

開啟 stress（若 +CORNER_STRESS=1），讓 bready/rready 等可隨機 backpressure

結束後 restore：stress off、hold_ready_high=1

Purpose

驗證 backpressure 下 driver/monitor/scoreboard 的穩定性

驗證 stall/retry/handshake 期間 ordering 不被破壞

Case 14: Corner Completion Suite (one-run “all required cases” regression)

Configuration

在同一個 run 內依序呼叫 Case 1~13（先 deterministic，再 stress，再 restore）

suite 結尾加 post-suite sanity（兩個 port 各做一次簡單 write/read）

Purpose

一次跑完即可宣告 corner coverage 完整（以 scoreboard mismatches=0 為準）

額外用 sanity 確認 driver/stress mode 已回復到乾淨狀態，避免“測完卡住”
