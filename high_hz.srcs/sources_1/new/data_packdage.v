`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/11/13 17:26:51
// Design Name: 
// Module Name: data_packdage
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module data_packdage(
input clk_50m,
input clk_400m,
input clk_200m,

input resetn,

input pack_vaild,
output pack_last,
output reg pack_busy,           //指示接口


input key,
input compare0,
input compare1,
output reg [127:0]data_pack   //外部接口


    );
    
 

localparam IDLE =6'b000001,
           NX =  6'b000010,
           N0 =  6'b000100,
           T1 =  6'b001000,
           P1 =  6'b010000,
           STO = 6'b100000;
           
reg [5:0]current_state,next_state; 
//ila_0 u_ila (
//	.clk(clk_50m), // input wire clk
//	.probe0(data_pack), // input wire [95:0] probe0
//	.probe1(compare0),
//	.probe2(pack_vaild),
//	.probe3(current_state)	
//);    
  
wire [26:0] nx_data;
wire [28:0] n0_data;
wire [63:0] t1_data;
wire [95:0] p1_data;

reg [26:0] nx_data_latch;  //data
reg [28:0] n0_data_latch;
reg [63:0] t1_data_latch;
reg [95:0] p1_data_latch;
wire nx_skip;
wire n0_skip;
wire t1_skip;
wire p1_skip;

wire [2:0] func_mux;
reg  [2:0] func_mux_latch;
reg pack_togo_sign;

reg n0_vaild,nx_vaild,t1_vaild,p1_vaild;
wire n0_last,nx_last,t1_last,p1_last;
reg n0_busy,nx_busy,t1_busy,p1_busy;

assign pack_last = 1'd1;
assign nx_skip =(func_mux_latch ==3'b001)?1'd1:1'd0;
assign n0_skip =(func_mux_latch ==3'b001)?1'd1:1'd0;            //低电平拉断resetn
assign t1_skip =(func_mux_latch ==3'b010)?1'd1:1'd0;
assign p1_skip =(func_mux_latch ==3'b100)?1'd1:1'd0;


//  ila_0 u_ila (
//	.clk(clk_50m), // input wire clk
//	.probe0(nx_data_latch), // input wire [95:0] probe0
//	.probe1(n0_data_latch),
//	.probe2(compare0),
//	.probe3(current_state)
	
//);






//=============================NX_握手==============================================


always @(posedge clk_50m or negedge resetn) begin
    if (!resetn)begin
        nx_vaild <= 1'b0;          
        end      
    else if(current_state == NX)begin
        nx_vaild <= 1'b1;   
        end
    else begin
        nx_vaild <= 1'b0;   
    end
end


//=============================N0_握手==============================================


always @(posedge clk_50m or negedge resetn) begin
    if (!resetn)begin
        n0_vaild <= 1'b0;          
        end      
    else if(current_state == N0)begin
        n0_vaild <= 1'b1;   
        end
    else begin
        n0_vaild <= 1'b0;   
    end
end

//=============================T1_握手==============================================


always @(posedge clk_50m or negedge resetn) begin
    if (!resetn)begin
        t1_vaild <= 1'b0;          
        end      
    else if(current_state == T1)begin
        t1_vaild <= 1'b1;   
        end
    else begin
        t1_vaild <= 1'b0;   
    end
end


//=============================P1_握手==============================================


always @(posedge clk_50m or negedge resetn) begin
    if (!resetn)begin
        p1_vaild <= 1'b0;          
        end      
    else if(current_state == P1)begin
        p1_vaild <= 1'b1;   
        end
    else begin
        p1_vaild <= 1'b0;   
    end
end


//=============================NX_DATA==============================================


always@(posedge clk_50m or negedge resetn)begin
if(!resetn)begin
nx_data_latch<=27'd0;
nx_busy  <= 1'b1; 
end
else if(nx_vaild && nx_last) begin
nx_data_latch<=nx_data;
nx_busy  <= 1'b0;
end
else begin
nx_data_latch<= nx_data_latch;
nx_busy  <= 1'b1;
end
end

//=============================N0_DATA==============================================
always@(posedge clk_50m or negedge resetn)begin
if(!resetn)begin
n0_data_latch<=29'd0;
n0_busy  <= 1'b1; 
end
else if(n0_vaild && n0_last) begin
n0_data_latch<=n0_data;
n0_busy  <= 1'b0;
end
else begin
n0_data_latch<= n0_data_latch;
n0_busy  <= 1'b1;
end
end


//=============================T1_DATA==============================================
always@(posedge clk_50m or negedge resetn)begin
if(!resetn)begin
t1_data_latch<=48'd0;
t1_busy  <= 1'b1; 
end
else if(t1_vaild && t1_last) begin
t1_data_latch<=t1_data;
t1_busy  <= 1'b0;
end
else begin
t1_data_latch<= t1_data_latch;
t1_busy  <= 1'b1;
end
end



//=============================P1_DATA==============================================
always@(posedge clk_50m or negedge resetn)begin
if(!resetn)begin
p1_data_latch<=95'd0;
p1_busy  <= 1'b1; 
end
else if(p1_vaild && p1_last) begin
p1_data_latch<=p1_data;
p1_busy  <= 1'b0;
end
else begin
p1_data_latch<= p1_data_latch;
p1_busy  <= 1'b1;
end
end




//===============================PACK_DATA============================================

always@(posedge clk_50m or negedge resetn)begin
if(!resetn)begin
data_pack <=128'd0;
pack_busy <=1'd0; 
end
else if((current_state == NX)  || (current_state == N0) || (current_state == T1) || (current_state == P1)) begin
data_pack <=128'd0;
pack_busy  <= 1'b1;
end
else if(current_state == STO) begin
case(func_mux_latch)
3'b001:begin
      data_pack <= {8'haa,8'haa,16'd0,5'b00000,nx_data_latch,3'b000,n0_data_latch,16'd0,16'hf0};
      pack_busy  <= 1'b0;
end
3'b010:begin
      data_pack <= {8'haa,8'hbb,16'd0,t1_data_latch,16'd0,16'hf0};
      pack_busy  <= 1'b0;
end
3'b100:begin
      data_pack <= {8'haa,8'hcc,p1_data_latch,16'hf0};
      pack_busy  <= 1'b0;
end
default: begin 
         data_pack <={16'haa,16'hee,16'hee,16'hee,16'hee,16'hee,16'hee,16'hf0}; 
         pack_busy  <= 1'b0;
         end
endcase
end
else begin
data_pack <=data_pack;
pack_busy =pack_busy; 
end
end



//===============================TOGO_SIGN============================================



always @(posedge clk_50m or negedge resetn) begin
    if (!resetn)
        pack_togo_sign <= 1'b0;
    else if(pack_last && pack_vaild)
        pack_togo_sign <= 1'd1;
    else 
        pack_togo_sign <= 1'd0;
end



//==============================状态机==============================================


always@(posedge clk_50m or negedge resetn)begin
if(!resetn)
current_state<=IDLE;
else
current_state<=next_state;
end


always@(*)begin
case(current_state)
IDLE:begin
      if(pack_togo_sign)begin
       func_mux_latch = func_mux;
       next_state = NX ;       
      end
      else begin
      next_state = IDLE ;
       end
     end
NX:begin
      if(!nx_busy || (!nx_skip))begin

      next_state = N0 ;      
      end
      else
      next_state = NX ;
     end
N0:begin
      if(!n0_busy || (!n0_skip))begin
      next_state = T1 ;      
      end
      else
      next_state = N0 ;
     end 
T1:begin
      if(!t1_busy || (!t1_skip))begin
      next_state = P1 ;      
      end
      else
      next_state = T1 ;
     end 
P1:begin
      if(!p1_busy || (!p1_skip))begin
      next_state = STO ;      
      end
      else
      next_state = P1 ;
     end 
STO:begin     
      if(!pack_busy)
      next_state = IDLE ; 
      else
      next_state = STO ; 
     end
default: begin
         next_state = IDLE ;
         end
endcase
end







nx_monitor u_nx(
.clk_50m        (clk_50m                ),
.clk_400m  (    clk_400m             )     ,
.resetn    (   resetn  && nx_skip          ) ,
.compare0  (   compare0              )      ,
.nx_vaild  (   nx_vaild              )     ,           // 来自 50M 域的握手响应（原 togo）
.nx_data   (   nx_data              )        ,
.nx_last   (   nx_last              )// 数据有效/握手标志（原 busy 的功能外化）
);

n0_monitor u_n0(
.clk_400m     (    clk_400m            )         ,     // 400MHz 主时钟
.resetn       (    resetn && n0_skip          )      ,       // 异步复位，低有效
.compare0     (    compare0             )      ,     // 被测信号（异步于 clk_400m）
.valid        (    n0_vaild            )       ,        // 50MHz 域握手响应（原 togo）
.n0_data      (    n0_data            )     ,      // 测量结果：compare0 上升沿间隔（400M 周期数）
.n0_last      (    n0_last            ) // 数据有效 / 握手标志（原 monitor_busy）
);


t1_monitor u_t1 (
    .clk_200m (clk_200m),
    .clk_50m (clk_50m),
    .resetn   (resetn && t1_skip),
    .compare0 (compare0),
    .compare1 (compare1),
    .tau_ps   (16'd19),        // 先用 20 ps 跑起来
    .t1_vaild (t1_vaild),
    .t1_data  (t1_data),
    .t1_last  (t1_last)
);



p1_monitor u_p1(
    .clk_200m     (   clk_200m                    )        ,     // 200MHz
    .resetn       (   resetn && p1_skip                    )  ,       // 异步复位，低有效
    .compare0     (   compare0                    )     ,     // 被测方波
    .p1_vaild     (   p1_vaild                    )      ,     // 50MHz 域 ack
    .p1_data      (   p1_data                    )         ,      // {0, k3, k2, k1, P_c, H_c}
    .p1_last      (   p1_last                    )
);


key_func #(
.DEBOUNCE_CNT (20'd1_000_000)   // 20 ms @ 50 MHz
)u_key(
.clk         (   clk_50m         )    ,          // 50 MHz
.resetn      (   resetn         )    ,       // 异步复位，低有效
.key         (   key         )   ,          // 按键，低有效
.func_mux    (   func_mux         )  // 001 / 010 / 100
);




endmodule
