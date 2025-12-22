UVM Compile & Simulation Issue Log

紀錄本專案在建立 AXI-MM UVM 驗證環境時遇到的所有編譯錯誤、警告、語法問題與解決方法。

1. 多變數賦值語法錯誤

原始寫法：

writes_seen_p0 = writes_seen_p1 = 0;
reads_seen_p0  = reads_seen_p1  = 0;


問題：
SV 不允許連續使用 = 同時設多變數，會被解析成表達式 → 語法錯誤。

正確寫法：

writes_seen_p0 = 0;
writes_seen_p1 = 0;
reads_seen_p0  = 0;
reads_seen_p1  = 0;

2. print_field_int 找不到

錯誤訊息：

Could not find field/method name (print_field_int) in 'printer'


原因： 舊版 UVM (pre-1.2) 不支援 print_field_int()。

解決方案：

printer.print_field("addr", addr, $bits(addr), UVM_HEX);

3. function 內呼叫 task → Warning

警告：

(vlog-2239) Treating stand-alone use of presumed external function as an implicit VOID cast.


原因：
function 不能含時間，也不能 call task。

解法：
把 function 改成 task，或改成 pure calculation function。

4. 巨集 WAIT_SIG 展開破壞語法

錯誤：

near "begin": syntax error, unexpected begin
near "++": syntax error, unexpected ++


原因：
Macro 換行缺 \，導致展開成不完整的 SV 程式碼。

5. task 不能 return

原本寫法：

task automatic logic [DATA_WIDTH-1:0] compute_expected_beat_read(...);


錯誤：

task does not allow return value


修正：

task automatic compute_expected_beat_read(
    ..., output logic [DATA_WIDTH-1:0] rdata);

6. 找不到 uvm_config_db

錯誤：

Undefined variable: 'uvm_config_db'
near "#": syntax error


原因：
檔案沒 include UVM package。

解決：

import uvm_pkg::*;
`include "uvm_macros.svh"

7. axi_mm_pkg include 順序錯誤

錯誤：

Could not find class 'axi_mm_driver'


原因：
package 中檔案 include 順序混亂。

修正（正確順序）：

seq_item

driver

monitor

agent

env

test

8. clocking block + ref → simulator warning

原因：
使用 clocking block ref（Questa 視為不建議或不支援）。

修正：
改用直接訊號，例如：

@(posedge vif.aclk);

9. virtual interface 沒設成功 → Null handle

錯誤：

FATAL: Null virtual interface


原因：
config_db 的 path 寫錯，例如：

"env.p0_agent"


或少 driver / monitor 層級。

10. randomize inline constraint 漏掉 with

錯誤：

syntax error, expecting ')'


原因：
寫成：

req.randomize() {


正確：

req.randomize() with {
};

11. monitor 誤用 clocking block event

錯誤：

@(posedge vif.cb_master)


原因：
不合法語法。

修正：

@(vif.cb_master);


或完全移除 clocking block。

12. scoreboard function 呼叫 task → VOID cast warning

再次出現 warning：

implicit VOID cast


解決：
將所有 function 改為 task，或把 task 拆成 pure function。

13. 重置等待 / handshake 於 function 中不允許

錯誤：
function 裡有時間控制（需要調用 task）會報錯或 warning。

解決方案：
全部移到 task。

14. burst default case 行為不明確

問題：
default 沒處理，導致覆蓋判定錯誤。

修正：
明確編碼 burst=FIXED / INCR / WRAP。

總結

這些錯誤包含：

UVM API 差異（舊版 UVM）

SystemVerilog 語法誤解

macro 展開陷阱

function/task 使用規範

package include 順序

interface + clocking block 限制

config_db path 層級錯誤

seq / driver / monitor 典型 UVM 程式設計議題






## 日期
2025-12-20

## 專案背景
- DUT: AXI-MM 雙埠 BRAM（dual-port RAM）  
- 執行環境: UVM Smoke Test  
- Port0: dma_clk domain  
- Port1: core_clk domain  
- 測試目標: 確認 write/read 功能正確，無 timeout 或 mismatch  

---

## 今日遇到的主要問題

### 1. Read Timeout 與 Write Timeout
- 初始 smoke_test 設定：
```text
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
```systemverilog
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