// ------------------------------------------------------------------------------
//   (c) Copyright 2020-2021 Advanced Micro Devices, Inc. All rights reserved.
// 
//   This file contains confidential and proprietary information
//   of Advanced Micro Devices, Inc. and is protected under U.S. and
//   international copyright and other intellectual property
//   laws.
// 
//   DISCLAIMER
//   This disclaimer is not a license and does not grant any
//   rights to the materials distributed herewith. Except as
//   otherwise provided in a valid license issued to you by
//   AMD, and to the maximum extent permitted by applicable
//   law: (1) THESE MATERIALS ARE MADE AVAILABLE \"AS IS\" AND
//   WITH ALL FAULTS, AND AMD HEREBY DISCLAIMS ALL WARRANTIES
//   AND CONDITIONS, EXPRESS, IMPLIED, OR STATUTORY, INCLUDING
//   BUT NOT LIMITED TO WARRANTIES OF MERCHANTABILITY, NON-
//   INFRINGEMENT, OR FITNESS FOR ANY PARTICULAR PURPOSE; and
//   (2) AMD shall not be liable (whether in contract or tort,
//   including negligence, or under any other theory of
//   liability) for any loss or damage of any kind or nature
//   related to, arising under or in connection with these
//   materials, including for any direct, or any indirect,
//   special, incidental, or consequential loss or damage
//   (including loss of data, profits, goodwill, or any type of
//   loss or damage suffered as a result of any action brought
//   by a third party) even if such damage or loss was
//   reasonably foreseeable or AMD had been advised of the
//   possibility of the same.
// 
//   CRITICAL APPLICATIONS
//   AMD products are not designed or intended to be fail-
//   safe, or for use in any application requiring fail-safe
//   performance, such as life-support or safety devices or
//   systems, Class III medical devices, nuclear facilities,
//   applications related to the deployment of airbags, or any
//   other applications that could lead to death, personal
//   injury, or severe property or environmental damage
//   (individually and collectively, \"Critical
//   Applications\"). Customer assumes the sole risk and
//   liability of any use of AMD products in Critical
//   Applications, subject only to applicable laws and
//   regulations governing limitations on product liability.
// 
//   THIS COPYRIGHT NOTICE AND DISCLAIMER MUST BE RETAINED AS
//   PART OF THIS FILE AT ALL TIMES.
//
// 
//
//       Owner:          
//       Revision:       $Id: $
//                       $Author: $
//                       $DateTime: $
//                       $Change: $
//       Description:
//
// 
////------------------------------------------------------------------------------

`timescale 1fs/1fs
(* DowngradeIPIdentifiedWarnings="yes" *)
////module lbus_if
module pcs64_pkt_gen_mon
(
  input                      gen_clk,
  input                      mon_clk,
  input                      dclk,
  input                      sys_reset,
  input                      send_continuous_pkts, 
  input wire                 restart_tx_rx,
  
  
//// RX Signals
  output wire         rx_reset,
  input  wire         user_rx_reset,
//// RX LBUS Signals
  input  wire [63:0] rx_mii_d,
  input  wire [7:0] rx_mii_c,
//// RX Control Signals
  output wire ctl_rx_test_pattern,
  output wire ctl_rx_test_pattern_enable,
  output wire ctl_rx_data_pattern_select,
  output wire ctl_rx_prbs31_test_pattern_enable,


//// RX Stats Signals
  input  wire stat_rx_block_lock,
  input  wire stat_rx_framing_err_valid,
  input  wire stat_rx_framing_err,
  input  wire stat_rx_hi_ber,
  input  wire stat_rx_valid_ctrl_code,
  input  wire stat_rx_bad_code,
  input  wire stat_rx_bad_code_valid,
  input  wire stat_rx_error_valid,
  input  wire [7:0] stat_rx_error,
  input  wire stat_rx_fifo_error,
  input  wire stat_rx_local_fault,

//// TX Signals
  output wire         tx_reset,
  input  wire         user_tx_reset,

//// TX LBUS Signals
  output wire [63:0] tx_mii_d,
  output wire [7:0] tx_mii_c,

//// TX Control Signals
  output wire ctl_tx_test_pattern,
  output wire ctl_tx_test_pattern_enable,
  output wire ctl_tx_test_pattern_select,
  output wire ctl_tx_data_pattern_select,
  output wire [57:0] ctl_tx_test_pattern_seed_a,
  output wire [57:0] ctl_tx_test_pattern_seed_b,
  output wire ctl_tx_prbs31_test_pattern_enable,



//// TX Stats Signals
  input  wire stat_tx_local_fault,

    output reg  [4:0]  completion_status,
    output wire        rx_gt_locked_led,
    output wire        rx_block_lock_led
   );

  parameter PKT_NUM         = 20;    //// Many Internal Counters are based on PKT_NUM = 20
  parameter FIXED_PACKET_LENGTH = 256;
  parameter MIN_LENGTH          = 64;
  parameter MAX_LENGTH          = 9000;

  wire [2:0] data_pattern_select;
  wire insert_crc;
  wire [4:0] completion_status_int;
  wire stat_rx_aligned;
  wire stat_rx_synced;
  wire pktgen_enable;
  reg  pktgen_enable_int;
  wire pktgen_enable_sync;
  
  wire tx_total_bytes_overflow;
  wire tx_sent_overflow;
  wire [31:0] tx_packet_count;
  wire [47:0] tx_sent_count;
  reg  [47:0] tx_sent_count_int;
  wire [47:0] tx_sent_count_sync;
  wire [63:0] tx_total_bytes;
  reg  [63:0] tx_total_bytes_int;
  wire [63:0] tx_total_bytes_sync;
  wire tx_time_out;
  reg  tx_time_out_int;
  wire tx_time_out_sync;
  wire tx_done;
  reg  tx_done_int;
  wire tx_done_sync;

  wire stat_rx_block_lock_sync;
  wire [31:0] rx_error_count;
  wire [31:0] rx_prot_err_count; 
  wire [63:0] rx_total_bytes;
  reg  [63:0] rx_total_bytes_int;
  wire [63:0] rx_total_bytes_sync;
  wire [47:0] rx_packet_count;
  reg  [47:0] rx_packet_count_int;
  wire [47:0] rx_packet_count_sync;
  wire rx_packet_count_overflow;
  wire rx_total_bytes_overflow;
  wire rx_prot_err_overflow;
  wire rx_error_overflow;
  
  wire rx_errors;
  reg  rx_errors_int;
  wire rx_errors_sync;
  wire rx_block_lock_sync;
  wire rx_data_err_count;
  wire rx_data_err_overflow;



  assign rx_errors            = |rx_prot_err_count || |rx_error_count ;
  assign tx_packet_count      = send_continuous_pkts ? 32'hFFFFFFFF : PKT_NUM;
  assign stat_rx_status       = stat_rx_block_lock_sync ;
  assign stat_rx_aligned      = stat_rx_block_lock_sync ;
  assign stat_rx_synced       = stat_rx_block_lock_sync ;
  assign data_pattern_select  = 3'd0;
  assign clear_count          = 1'b0;
  assign insert_crc           = 1'b0;
pcs64_user_cdc_sync i_pcs64_core_cdc_sync_block_lock_syncer (
    .clk                 (dclk),
    .signal_in           (stat_rx_block_lock),
    .signal_out          (stat_rx_block_lock_sync)
  );

pcs64_user_cdc_sync i_pcs64_core_cdc_sync_block_lock_syncer_gen (
    .clk                 (gen_clk),
    .signal_in           (stat_rx_block_lock),
    .signal_out          (rx_block_lock_sync)
  );

  always @(posedge gen_clk)
  begin
      tx_total_bytes_int  <= tx_total_bytes;
  end
  
pcs64_cdc_sync_2stage 
  #(
    .WIDTH        (64)
  ) i_pcs64_tx_total_bytes_syncer (
    .clk          (dclk ),
    .signal_in    (tx_total_bytes_int),
    .signal_out   (tx_total_bytes_sync)
  );

  always @(posedge gen_clk)
  begin
      tx_sent_count_int <= tx_sent_count;
  end

pcs64_cdc_sync_2stage 
  #(
    .WIDTH        (48)
  ) i_pcs64_tx_packet_count_syncer (
    .clk          (dclk ),
    .signal_in    (tx_sent_count_int),
    .signal_out   (tx_sent_count_sync)
  );

  always @(posedge gen_clk)
  begin
      tx_time_out_int   <= tx_time_out ;
  end

pcs64_cdc_sync_2stage 
  #(
    .WIDTH        (1)
  ) i_pcs64_tx_time_out_syncer (
    .clk          (dclk ),
    .signal_in    (tx_time_out_int),
    .signal_out   (tx_time_out_sync)
  );

  always @(posedge gen_clk)
  begin
      tx_done_int       <= tx_done ;
  end

pcs64_cdc_sync_2stage 
  #(
    .WIDTH        (1)
  ) i_pcs64_tx_done_syncer (
    .clk          (dclk ),
    .signal_in    (tx_done_int),
    .signal_out   (tx_done_sync)
  );

  always @(posedge mon_clk)
  begin
      rx_packet_count_int <= rx_packet_count;
  end

pcs64_cdc_sync_2stage 
  #(
    .WIDTH        (48)
  ) i_pcs64_rx_packet_count_syncer (
    .clk          (dclk ),
    .signal_in    (rx_packet_count_int),
    .signal_out   (rx_packet_count_sync)
  );

  always @(posedge mon_clk)
  begin
      rx_total_bytes_int  <= rx_total_bytes;
  end

pcs64_cdc_sync_2stage 
  #(
    .WIDTH        (64)
  ) i_pcs64_rx_total_bytes_syncer (
    .clk          (dclk ),
    .signal_in    (rx_total_bytes_int),
    .signal_out   (rx_total_bytes_sync)
  );

  always @(posedge mon_clk)
  begin
      rx_errors_int       <= rx_errors;
  end

pcs64_cdc_sync_2stage 
  #(
    .WIDTH        (1)
  ) i_pcs64_rx_errors_syncer (
    .clk          (dclk ),
    .signal_in    (rx_errors_int),
    .signal_out   (rx_errors_sync)
  );



  always@ (posedge dclk)
  begin
      pktgen_enable_int <= pktgen_enable;
  end

pcs64_user_cdc_sync i_pcs64_core_cdc_sync_pkt_gen_enable (
    .clk                 (gen_clk),
    .signal_in           (pktgen_enable_int),
    .signal_out          (pktgen_enable_sync)
);

wire rx_data_err_count_sync;
reg rx_data_err_reg;
  always@ (posedge mon_clk)
begin
    rx_data_err_reg <= rx_data_err_count;
end

pcs64_cdc_sync_2stage 
  #(
    .WIDTH        (1)
  ) xxv_ethernet_5_rx_data_err_syncer (
    .clk          (dclk ),
    .signal_in    (rx_data_err_reg),
    .signal_out   (rx_data_err_count_sync)
  );
  wire  ok_to_start;
  assign ok_to_start = 1'b1;
pcs64_example_fsm  
   i_pcs64_EXAMPLE_FSM  (
  .dclk                        (dclk),
  .fsm_reset                   (sys_reset| restart_tx_rx),
  .send_continuous_pkts        (send_continuous_pkts),
  .stat_rx_block_lock          (stat_rx_block_lock_sync),
  .stat_rx_synced              (stat_rx_synced),
  .stat_rx_aligned             (stat_rx_aligned),
  .stat_rx_status              (stat_rx_status),
  .tx_timeout                  (tx_time_out_sync),
  .tx_done                     (tx_done_sync),
  .ok_to_start                 (ok_to_start),
  .rx_packet_count             (rx_packet_count_sync),
  .rx_total_bytes              (rx_total_bytes_sync),
  .rx_errors                   (rx_errors_sync),
  .rx_data_errors              (rx_data_err_count_sync),
  .tx_sent_count               (tx_sent_count_sync),
  .tx_total_bytes              (tx_total_bytes_sync),
  .sys_reset                   (   ),
  .pktgen_enable               (pktgen_enable),
  .completion_status           (completion_status_int)
);
  always @( posedge dclk, posedge sys_reset  )
  begin
      if ( sys_reset == 1'b1 )
      begin
          completion_status    <= 5'b0;
      end
      else
      begin
          completion_status    <= completion_status_int;
      end
  end

pcs64_mii_traffic_gen_mon  #(
  .FIXED_PACKET_LENGTH ( FIXED_PACKET_LENGTH ),
  .TRAF_MIN_LENGTH     ( MIN_LENGTH ),
  .TRAF_MAX_LENGTH     ( MAX_LENGTH )
) i_pcs64_mii_gen_mon (
  .tx_clk (gen_clk),
  .tx_reset (user_tx_reset | restart_tx_rx),
  .rx_clk (mon_clk),
  .rx_reset (user_rx_reset | restart_tx_rx),
  .sys_reset (sys_reset),
  .pktgen_enable (pktgen_enable_sync),
  .send_continuous_pkts (send_continuous_pkts),
  .insert_crc (insert_crc),
  .tx_packet_count (tx_packet_count),
  .clear_count (clear_count),
  .rx_mii_d (rx_mii_d),
  .rx_mii_c (rx_mii_c),
  //.rx_lane_align (stat_rx_status),
  .rx_lane_align (stat_rx_block_lock),
  .tx_mii_d (tx_mii_d),
  .tx_mii_c (tx_mii_c),
  .rx_reset_out (rx_reset),
  .tx_reset_out (tx_reset),

//// RX Control Signals
  .ctl_rx_test_pattern (ctl_rx_test_pattern),
  .ctl_rx_test_pattern_enable (ctl_rx_test_pattern_enable),
  .ctl_rx_data_pattern_select (ctl_rx_data_pattern_select),
  .ctl_rx_prbs31_test_pattern_enable (ctl_rx_prbs31_test_pattern_enable),


//// RX Stats Signals
  .stat_rx_block_lock (stat_rx_block_lock),
  .stat_rx_framing_err_valid (stat_rx_framing_err_valid),
  .stat_rx_framing_err (stat_rx_framing_err),
  .stat_rx_hi_ber (stat_rx_hi_ber),
  .stat_rx_valid_ctrl_code (stat_rx_valid_ctrl_code),
  .stat_rx_bad_code (stat_rx_bad_code),
  .stat_rx_bad_code_valid (stat_rx_bad_code_valid),
  .stat_rx_error_valid (stat_rx_error_valid),
  .stat_rx_error (stat_rx_error),
  .stat_rx_fifo_error (stat_rx_fifo_error),
  .stat_rx_local_fault (stat_rx_local_fault),


//// TX Control Signals
  .ctl_tx_test_pattern (ctl_tx_test_pattern),
  .ctl_tx_test_pattern_enable (ctl_tx_test_pattern_enable),
  .ctl_tx_test_pattern_select (ctl_tx_test_pattern_select),
  .ctl_tx_data_pattern_select (ctl_tx_data_pattern_select),
  .ctl_tx_test_pattern_seed_a (ctl_tx_test_pattern_seed_a),
  .ctl_tx_test_pattern_seed_b (ctl_tx_test_pattern_seed_b),
  .ctl_tx_prbs31_test_pattern_enable (ctl_tx_prbs31_test_pattern_enable),


//// TX Stats Signals
  .stat_tx_local_fault (stat_tx_local_fault),

  .tx_time_out (tx_time_out),
  .tx_done (tx_done),
  .rx_protocol_error (rx_protocol_error),
  .rx_packet_count (rx_packet_count),
  .rx_total_bytes (rx_total_bytes),
  .rx_prot_err_count (rx_prot_err_count),
  .rx_error_count (rx_error_count),
  .rx_packet_count_overflow (rx_packet_count_overflow),
  .rx_total_bytes_overflow (rx_total_bytes_overflow),
  .rx_prot_err_overflow (rx_prot_err_overflow),
  .rx_error_overflow (rx_error_overflow),
  .tx_sent_count (tx_sent_count),
  .tx_sent_overflow (tx_sent_overflow),
  .tx_total_bytes (tx_total_bytes),
  .tx_total_bytes_overflow (tx_total_bytes_overflow),
  .rx_data_err_count (rx_data_err_count),
  .rx_data_err_overflow (rx_data_err_overflow),
  .rx_gt_locked_led (rx_gt_locked_led),
  .rx_block_lock_led (rx_block_lock_led)
);



  


endmodule
(* DowngradeIPIdentifiedWarnings="yes" *)
module pcs64_cdc_sync_2stage
#(
 parameter WIDTH  = 1
)
(
 input  clk,
 input  [WIDTH-1:0] signal_in,
 output wire [WIDTH-1:0]  signal_out
);

                          wire [WIDTH-1:0] sig_in_cdc_from;
 (* ASYNC_REG = "TRUE" *) reg  [WIDTH-1:0] s_out_d2_cdc_to;
 (* ASYNC_REG = "TRUE" *) reg  [WIDTH-1:0] data_out_d3;

assign sig_in_cdc_from = signal_in;
assign signal_out      = data_out_d3;

always @(posedge clk) 
begin
  s_out_d2_cdc_to  <= sig_in_cdc_from;
  data_out_d3      <= s_out_d2_cdc_to;
end

endmodule

(* DowngradeIPIdentifiedWarnings="yes" *)
  module pcs64_user_cdc_sync (
   input clk,
   input signal_in,
   output reg signal_out
  );
  
                                wire sig_in_cdc_from ;
       (* ASYNC_REG = "TRUE" *) reg  s_out_d2_cdc_to;
       (* ASYNC_REG = "TRUE" *) reg  s_out_d3;
       (* ASYNC_REG = "TRUE" *) reg  s_out_d4;
      
      assign sig_in_cdc_from = signal_in;
      
      always @(posedge clk) 
      begin
        signal_out       <= s_out_d4;
        s_out_d4         <= s_out_d3;
        s_out_d3         <= s_out_d2_cdc_to;
        s_out_d2_cdc_to  <= sig_in_cdc_from;
      end

  endmodule
module pcs64_mii_traffic_gen_mon #(
  parameter integer FIXED_PACKET_LENGTH = 9_000,
                    TRAF_MIN_LENGTH = 64,
                    TRAF_MAX_LENGTH = 9000
               ) (

  input  wire tx_clk,
  input  wire rx_clk,
  input  wire tx_reset,
  input  wire rx_reset,
  input  wire sys_reset,
  input  wire pktgen_enable,
  input  wire send_continuous_pkts,
  input  wire insert_crc,
  input  wire [31:0] tx_packet_count,
  input  wire clear_count,
  input  wire [63:0] rx_mii_d,
  input  wire [7:0]  rx_mii_c,
  input  wire rx_lane_align,
  output wire tx_reset_out,
  output wire rx_reset_out,
//// RX Control Signals
  output wire ctl_rx_test_pattern,
  output wire ctl_rx_test_pattern_enable,
  output wire ctl_rx_data_pattern_select,
  output wire ctl_rx_prbs31_test_pattern_enable,


//// RX Stats Signals
  input  wire stat_rx_block_lock,
  input  wire stat_rx_framing_err_valid,
  input  wire stat_rx_framing_err,
  input  wire stat_rx_hi_ber,
  input  wire stat_rx_valid_ctrl_code,
  input  wire stat_rx_bad_code,
  input  wire stat_rx_bad_code_valid,
  input  wire stat_rx_error_valid,
  input  wire [7:0] stat_rx_error,
  input  wire stat_rx_fifo_error,
  input  wire stat_rx_local_fault,

//// TX Control Signals
  output wire ctl_tx_test_pattern,
  output wire ctl_tx_test_pattern_enable,
  output wire ctl_tx_test_pattern_select,
  output wire ctl_tx_data_pattern_select,
  output wire [57:0] ctl_tx_test_pattern_seed_a,
  output wire [57:0] ctl_tx_test_pattern_seed_b,
  output wire ctl_tx_prbs31_test_pattern_enable,


//// TX Stats Signals
  input  wire stat_tx_local_fault,

  output  wire [63:0] tx_mii_d,
  output  wire [7:0]  tx_mii_c,

  output wire tx_time_out,
  output wire tx_done,
  output wire rx_protocol_error,
  output wire [47:0] rx_packet_count,
  output wire [63:0] rx_total_bytes,
  output wire [31:0] rx_prot_err_count,
  output wire [31:0] rx_error_count,
  output wire rx_packet_count_overflow,
  output wire rx_total_bytes_overflow,
  output wire rx_prot_err_overflow,
  output wire rx_error_overflow,
  output wire [47:0] tx_sent_count,
  output wire tx_sent_overflow,
  output wire [63:0] tx_total_bytes,
  output wire tx_total_bytes_overflow,
  output wire rx_data_err_count,
  output wire rx_data_err_overflow,
  output wire rx_gt_locked_led,
  output wire rx_block_lock_led

);
  assign rx_mii_clk = rx_clk ;
  wire pkt_tx_busy;
  wire rx_gt_locked_led_int;
  assign rx_gt_locked_led = rx_gt_locked_led_int;
  
  assign rx_data_err_count = |rx_error_count;
  assign rx_data_err_overflow    = rx_error_overflow;
pcs64_mii_pkt_gen
  #(
  .pkt_len ( FIXED_PACKET_LENGTH )
  ) i_pcs64_PKT_GEN1 (                       // Generator to send 1 packet
  .tx_mii_clk ( tx_clk ),
  .tx_mii_reset ( tx_reset ),
  .tx_reset ( tx_reset_out ),

  .enable ( pktgen_enable ),
  .insert_crc ( insert_crc ),
  .packet_count ( tx_packet_count ),
  .send_continuous_pkts ( send_continuous_pkts ),
//// TX Control Signals
  .ctl_tx_test_pattern (ctl_tx_test_pattern),
  .ctl_tx_test_pattern_enable (ctl_tx_test_pattern_enable),
  .ctl_tx_test_pattern_select (ctl_tx_test_pattern_select),
  .ctl_tx_data_pattern_select (ctl_tx_data_pattern_select),
  .ctl_tx_test_pattern_seed_a (ctl_tx_test_pattern_seed_a),
  .ctl_tx_test_pattern_seed_b (ctl_tx_test_pattern_seed_b),
  .ctl_tx_prbs31_test_pattern_enable (ctl_tx_prbs31_test_pattern_enable),


//// TX Stats Signals
  .stat_tx_local_fault (stat_tx_local_fault),

  .tx_mii_d ( tx_mii_d ),
  .tx_mii_c ( tx_mii_c ),

  .time_out ( tx_time_out ),
  .busy ( pkt_tx_busy ),
  .done ( tx_done )
);

pcs64_mii_traf_chk i_pcs64_TRAF_CHK1 (

  .mii_clk          ( rx_clk ),
  .mii_reset        ( rx_reset ),
  .sys_reset        ( sys_reset ),
  .enable           ( 1'b1 ),
  .clear_count      ( clear_count ),
  .rx_reset         ( rx_reset_out ),
  .mii_d            ( rx_mii_d ),
  .mii_c            ( rx_mii_c ),
//// RX Control Signals
  .ctl_rx_test_pattern (ctl_rx_test_pattern),
  .ctl_rx_test_pattern_enable (ctl_rx_test_pattern_enable),
  .ctl_rx_data_pattern_select (ctl_rx_data_pattern_select),
  .ctl_rx_prbs31_test_pattern_enable (ctl_rx_prbs31_test_pattern_enable),


//// RX Stats Signals
  .stat_rx_block_lock (stat_rx_block_lock),
  .stat_rx_framing_err_valid (stat_rx_framing_err_valid),
  .stat_rx_framing_err (stat_rx_framing_err),
  .stat_rx_hi_ber (stat_rx_hi_ber),
  .stat_rx_valid_ctrl_code (stat_rx_valid_ctrl_code),
  .stat_rx_bad_code (stat_rx_bad_code),
  .stat_rx_bad_code_valid (stat_rx_bad_code_valid),
  .stat_rx_error_valid (stat_rx_error_valid),
  .stat_rx_error (stat_rx_error),
  .stat_rx_fifo_error (stat_rx_fifo_error),
  .stat_rx_local_fault (stat_rx_local_fault),

  .protocol_error ( rx_protocol_error ),
  .packet_count ( rx_packet_count ),
  .total_bytes ( rx_total_bytes ),
  .prot_err_count ( rx_prot_err_count ),
  .error_count ( rx_error_count ),
  .packet_count_overflow ( rx_packet_count_overflow ),
  .total_bytes_overflow ( rx_total_bytes_overflow ),
  .prot_err_overflow ( rx_prot_err_overflow ),
  .error_overflow ( rx_error_overflow ),
  .rx_gt_locked_led (rx_gt_locked_led_int),
  .rx_block_lock_led (rx_block_lock_led)
);

pcs64_mii_traf_gen_chk i_pcs64_TRAF_CHK2 (                         //// Counter for packets sent

  .mii_clk ( tx_clk ),
  .mii_reset ( tx_reset ),
  .enable ( pktgen_enable || pkt_tx_busy ),
  .clear_count ( clear_count ),

  .mii_d ( tx_mii_d ),
  .mii_c ( tx_mii_c ),

  .protocol_error ( ),
  .packet_count ( tx_sent_count ),
  .total_bytes ( tx_total_bytes ),
  .prot_err_count ( ),
  .error_count ( ),
  .packet_count_overflow ( tx_sent_overflow ),
  .total_bytes_overflow ( tx_total_bytes_overflow ),
  .prot_err_overflow ( ),
  .error_overflow ( )
);

endmodule
module pcs64_example_fsm #( 
 parameter VL_LANES_PER_GENERATOR = 1
)(
input wire dclk,
input wire fsm_reset,
input wire send_continuous_pkts,
input wire [VL_LANES_PER_GENERATOR-1:0] stat_rx_block_lock,
input wire [VL_LANES_PER_GENERATOR-1:0] stat_rx_synced,
input wire stat_rx_aligned,
input wire stat_rx_status,
input wire tx_timeout,
input wire tx_done,
input wire ok_to_start,

input wire [47:0] rx_packet_count,
input wire [63:0] rx_total_bytes,
input wire  rx_errors,
input wire  rx_data_errors,
input wire [47:0] tx_sent_count,
input wire [63:0] tx_total_bytes,


output reg sys_reset,
output reg pktgen_enable,

output reg [4:0] completion_status
);


`ifdef SIM_SPEED_UP
 parameter [31:0] STARTUP_TIME = 32'd5000;
`else
 parameter [31:0] STARTUP_TIME = 32'd50_000;
`endif
 parameter        GENERATOR_COUNT = 1;
 localparam [4:0]   NO_START = {5{1'b1}},
                   TEST_START = 5'd0,
                   SUCCESSFUL_COMPLETION = 5'd1,
                   NO_BLOCK_LOCK = 5'd2,
                   PARTIAL_BLOCK_LOCK = 5'd3,
                   INCONSISTENT_BLOCK_LOCK = 5'd4,
                   NO_LANE_SYNC = 5'd5,
                   PARTIAL_LANE_SYNC = 5'd6,
                   INCONSISTENT_LANE_SYNC = 5'd7,
                   NO_ALIGN_OR_STATUS = 5'd8,
                   LOSS_OF_STATUS = 5'd9,
                   TX_TIMED_OUT = 5'd10,
                   NO_DATA_SENT = 5'd11,
                   SENT_COUNT_MISMATCH = 5'd12,
                   BYTE_COUNT_MISMATCH = 5'd13,
                   LBUS_PROTOCOL = 5'd14,
                   BIT_ERRORS_IN_DATA = 5'd15;

/* Parameter definitions of STATE variables for 5 bit state machine */
localparam [4:0]  S0 = 5'b00000,     // S0 = 0
                  S1 = 5'b00001,     // S1 = 1
                  S2 = 5'b00011,     // S2 = 3
                  S3 = 5'b00010,     // S3 = 2
                  S4 = 5'b00110,     // S4 = 6
                  S5 = 5'b00111,     // S5 = 7
                  S6 = 5'b00101,     // S6 = 5
                  S7 = 5'b00100,     // S7 = 4
                  S8 = 5'b01100,     // S8 = 12
                  S9 = 5'b01101,     // S9 = 13
                  S10 = 5'b01111,     // S10 = 15
                  S11 = 5'b01110,     // S11 = 14
                  S12 = 5'b01010,     // S12 = 10
                  S13 = 5'b01011,     // S13 = 11
                  S14 = 5'b01001,     // S14 = 9
                  S15 = 5'b01000,     // S15 = 8
                  S16 = 5'b11000,     // S16 = 24
                  S17 = 5'b11001;     // S17 = 25


reg [4:0] state ;
reg [31:0] common_timer;
reg rx_packet_count_mismatch;
reg rx_byte_count_mismatch;
reg rx_non_zero_error_count;
reg tx_zero_sent;
wire send_continuous_pkts_sync;
pcs64_user_cdc_sync i_pcs64_send_continuous_pkts_dclk_syncer_syncer (
    .clk                 (dclk),
    .signal_in           (send_continuous_pkts),
    .signal_out          (send_continuous_pkts_sync)
  );

always @( posedge dclk )
    begin
      if ( fsm_reset == 1'b1 ) begin
        common_timer <= 0;
        state <= S0;
        sys_reset <= 1'b0 ;
        pktgen_enable <= 1'b0;
        completion_status <= NO_START ;
        rx_packet_count_mismatch <= 0;
        rx_byte_count_mismatch <= 0;
        rx_non_zero_error_count <= 0;
        tx_zero_sent <= 0;
      end
      else begin :check_loop
        integer i;
        common_timer <= |common_timer ? common_timer - 1 : common_timer;
        rx_non_zero_error_count <=  rx_data_errors ;
        rx_packet_count_mismatch <= 0;
        rx_byte_count_mismatch <= 0;
        tx_zero_sent <= 0;
        for ( i = 0; i < GENERATOR_COUNT; i=i+1 ) begin
          if ( tx_total_bytes[(64 * i)+:64] != rx_total_bytes[(64 * i)+:64] ) rx_byte_count_mismatch <= 1'b1;
          if ( tx_sent_count[(48 * i)+:48] != rx_packet_count[(48 * i)+:48] ) rx_packet_count_mismatch <= 1'b1;         // Check all generators for received counts equal transmitted count
          if ( ~|tx_sent_count[(48 * i)+:48] ) tx_zero_sent <= 1'b1;                                                       // If any channel fails to send any data, flag zero-sent
        end
        case ( state )
          S0: state <= ok_to_start ? S1 : S0;
          S1: begin
`ifdef SIM_SPEED_UP
                common_timer <= cvt_us ( 32'd100 );               // If this is the example simulation then only wait for 100 us
`else
                common_timer <= cvt_us ( 32'd10_000 );               // Wait for 10ms...do nothing; settling time for MMCs, oscilators, QPLLs etc.
`endif
                completion_status <= TEST_START;
                state <= S2;
              end
          S2: state <= (|common_timer) ? S2 : S3;
          S3: begin
                common_timer <= 3;
                sys_reset <= 1'b1;
                state <= S4;
              end
          S4: state <= (|common_timer) ? S4 : S5;
          S5: begin
                common_timer <= cvt_us( 5 );                    // Allow about 5 us for the reset to propagate into the downstream hardware
                sys_reset <= 1'b0;     // Clear the reset
                state <= S16;
              end
         S16: state <= (|common_timer) ? S16 : S17;
         S17: begin
                common_timer <= cvt_us( STARTUP_TIME );            // Set 20ms wait period
                state <= S6;
              end
          S6: if(|common_timer) state <= |stat_rx_block_lock ? S7 : S6 ;
              else begin
                state <= S15;
                completion_status <= NO_BLOCK_LOCK;
              end
          S7: if(|common_timer) state <= &stat_rx_block_lock ? S8 : S7 ;
              else begin
                state <= S15;
                completion_status <= PARTIAL_BLOCK_LOCK;
              end
          S8: if(|common_timer) begin
                if( ~&stat_rx_block_lock ) begin
                  state <= S15;
                  completion_status <= INCONSISTENT_BLOCK_LOCK;
                end
                else state <= |stat_rx_synced ? S9 : S8 ;
              end
              else begin
                state <= S15;
                completion_status <= NO_LANE_SYNC;
              end
          S9: if(|common_timer) begin
                if( ~&stat_rx_block_lock ) begin
                  state <= S15;
                  completion_status <= INCONSISTENT_BLOCK_LOCK;
                end
                else state <= &stat_rx_synced ? S10 : S9 ;
              end
              else begin
                state <= S15;
                completion_status <= PARTIAL_LANE_SYNC;
              end
          S10: if(|common_timer) begin
                if( ~&stat_rx_block_lock ) begin
                  state <= S15;
                  completion_status <= INCONSISTENT_BLOCK_LOCK;
                end
                else if( ~&stat_rx_synced ) begin
                  state <= S15;
                  completion_status <= INCONSISTENT_LANE_SYNC;
                end
                else begin
                  state <= (stat_rx_aligned && stat_rx_status ) ? S11 : S10 ;
                end
              end
              else begin
                state <= S15;
                completion_status <= NO_ALIGN_OR_STATUS;
              end
          S11: begin
                 state <= S12;
`ifdef SIM_SPEED_UP
                 common_timer <= cvt_us( 32'd50 );            // Set 50us wait period while aligned (simulation only )
`else
                 common_timer <= cvt_us( 32'd1_000 );            // Set 1ms wait period while aligned
`endif
               end
          S12: if(|common_timer) begin
                 if( ~&stat_rx_block_lock || ~&stat_rx_synced || ~stat_rx_aligned || ~stat_rx_status ) begin
                   state <= S15;
                   completion_status <= LOSS_OF_STATUS;
                 end
               end
               else begin
                state <= S13;
                pktgen_enable <= 1'b1;                          // Turn on the packet generator
`ifdef SIM_SPEED_UP
                common_timer <= cvt_us ( 32'd200 );               // If this is the example simulation then only wait for 100 us
`else
                common_timer <= cvt_us( 32'd10_000 );
`endif
              end
          S13: if(|common_timer) begin
                 if( ~&stat_rx_block_lock || ~&stat_rx_synced || ~stat_rx_aligned || ~stat_rx_status ) begin
                   state <= S15;
                   completion_status <= LOSS_OF_STATUS;
                 end
                 if(send_continuous_pkts_sync) begin
`ifdef SIM_SPEED_UP
                   common_timer <= cvt_us( 32'd50); // After send_continuous_pkts becomes "0" simulation wait for 50 us
`else
                   common_timer <= cvt_us( 32'd1_000); // After send_continuous_pkts becomes "0" simulation wait for 1 ms
`endif
                 end
               end
               else state <= S14;
          S14: begin
                 state <= S15;
                 completion_status <= SUCCESSFUL_COMPLETION;
                 if(tx_timeout || ~tx_done) completion_status <= TX_TIMED_OUT;
                 else if(rx_packet_count_mismatch) completion_status <= SENT_COUNT_MISMATCH;
                 else if(rx_byte_count_mismatch) completion_status <= BYTE_COUNT_MISMATCH;
                 else if(rx_errors) completion_status <= LBUS_PROTOCOL;
                 else if(rx_non_zero_error_count) completion_status <= BIT_ERRORS_IN_DATA;
                 else if(tx_zero_sent) completion_status <= NO_DATA_SENT;
               end
          S15: state <= S15;            // Finish and wait forever
        endcase
      end
    end


function [31:0] cvt_us( input [31:0] d );
cvt_us = ( ( d * 300 ) + 3 ) / 4 ;
endfunction

endmodule

module pcs64_mii_pkt_gen
  #(
  parameter integer pkt_len = 300
  ) (                       // Generator to send 1 packet

  input  wire enable,
  input  wire insert_crc,
  input  wire send_continuous_pkts,

 

  input  wire tx_mii_clk,
  input  wire tx_mii_reset,
  output  reg [63:0] tx_mii_d,
  output  reg [7:0]  tx_mii_c,
  output  wire  tx_reset,
  input  wire [31:0] packet_count,
  
//// TX Control Signals
  output wire ctl_tx_test_pattern,
  output wire ctl_tx_test_pattern_enable,
  output wire ctl_tx_test_pattern_select,
  output wire ctl_tx_data_pattern_select,
  output wire [57:0] ctl_tx_test_pattern_seed_a,
  output wire [57:0] ctl_tx_test_pattern_seed_b,
  output wire ctl_tx_prbs31_test_pattern_enable,


//// TX Stats Signals
  input  wire stat_tx_local_fault,

  output wire time_out,                 // 1 second timeout
  output reg  busy,
  output wire done
);

reg [1:0] q_en;
reg [2:0] state;
reg [31:0] rand1;
wire [31:0] nxt_rand1;
wire [63:0] nxt_d;
reg [63:0] d_buff;
reg [31:0] counter;
reg [63:0] op_data;
reg [1:0] d_sel;

wire [63:0]  op_mask;
reg [29:0] op_timer;
reg [31:0] packet_counter;
reg z_pkt;
reg [2:0] bsy_cntr;
wire [1:0] data_select;

assign data_select                        = 2'b0;
assign tx_reset                           = 1'b0;

assign ctl_tx_enable                      = 1'b1;
assign ctl_tx_test_pattern                = 1'b0;
assign ctl_tx_test_pattern_select         = 1'b0;
assign ctl_tx_test_pattern_enable         = 1'b0;
assign ctl_tx_data_pattern_select         = 1'b0;
assign ctl_tx_test_pattern_seed_a         = 58'h0;
assign ctl_tx_test_pattern_seed_b         = 58'h0;
assign ctl_tx_prbs31_test_pattern_enable  = 1'b0;
assign ctl_local_loopback                 = 1'b1;
assign ctl_FEC_Enable_Error_to_PCS        = 'd0;
assign ctl_FEC_TX_Enable                  = 'd0;


localparam [63:0] preamble   = 64'hFB_55_55_55_55_55_55_D5 ;      // Broadcast
localparam [47:0] dest_addr   = 48'hFF_FF_FF_FF_FF_FF;            // Broadcast
localparam [47:0] source_addr = 48'h14_FE_B5_DD_9A_82;            // Hardware address of xowjcoppens40
localparam [15:0] length_type = 16'h0600;                       // XEROX NS IDP
localparam [175:0] eth_header = { preamble, dest_addr, source_addr, length_type} ;

localparam [32:0] CRC_POLYNOMIAL = 33'b100000100110000010001110110110111;
//     G(x) = x32 + x26 + x23 + x22 + x16 + x12 + x11 + x10 + x8 + x7 + x5 + x4 + x2 + x + 1

localparam [32:0] DATA_POLYNOMIAL = 33'b100001000001010000000010010000001;
localparam [31:0] init_crc = 32'b11010111011110111101100110001011;

localparam integer xfer_cnt = pkt_len/8,
                   xfer_rmdr = pkt_len%8 ,
                   nz_rmdr = ( xfer_rmdr == 0 ) ? 1 : xfer_rmdr ;
localparam [7:0] xfer_ctl = (xfer_rmdr==0) ? { 8 { 1'b0 }} : { { 8-nz_rmdr{1'b1}}, {nz_rmdr{1'b0}} } ;

localparam integer crc_cnt = (pkt_len-4)/8,
                   crc_rmdr = (pkt_len-4)%8,
                   crc_insrt = (xfer_rmdr == 0) ? 0 : (64 - (xfer_rmdr * 8)),
                   crc_bits = (xfer_rmdr >= 4) ? 32 : (xfer_rmdr*8),
                   nz_bits = (crc_bits == 0) ? 32 : crc_bits,
                   crc_residue_bits = (crc_cnt != xfer_cnt) ? (32 - crc_bits) : 32,
                   crc_residue_start = (crc_cnt != xfer_cnt) ? crc_bits : 0;


localparam integer full_bits = xfer_rmdr * 8,
                   empty_bits =  64 - full_bits;
generate
if (full_bits==0) assign op_mask = {64{1'b1}} ;
else assign op_mask = { {full_bits{1'b1}} , {empty_bits{1'b0}} } ;
endgenerate
reg set_eop;
reg [1:0] idle_cycle;

localparam [31:0] PKT0_CRC = gen_CRC_const(pkt_len-4,1'b0);
localparam [31:0] PKT1_CRC = gen_CRC_const(pkt_len-4,1'b1);
localparam [31:0] PKT3_CRC = gen_CRC3(pkt_len-4);

reg [31:0] op_crc;
reg en_residue;

reg [8:0] header_bit_count ;

always @(*) case(d_sel)
  2'b00: begin op_data = {64{1'b0}}; op_crc = PKT0_CRC; end
  2'b01: begin op_data = {64{1'b1}}; op_crc = PKT1_CRC; end
  default: begin op_data = d_buff; op_crc = PKT3_CRC; end
endcase

/* Parameter definitions of STATE variables for 3 bit state machine */

localparam [2:0]
    S0  = 3'b000,           // S0  = 0
    S1  = 3'b001,           // S1  = 1
    S2  = 3'b011,           // S2  = 3
    S3  = 3'b010,           // S3  = 2
    S4  = 3'b110,           // S4  = 6
    S5  = 3'b111,           // S5  = 7
    S6  = 3'b101,           // S6  = 5
    S7  = 3'b100;           // S7  = 4

pcs64_pcs_pktprbs_gen #(
  .BIT_COUNT(64)
) i_pcs64_PKT_PRBS_GEN (
  .ip(rand1),
  .op(nxt_rand1),
  .datout(nxt_d)
);

  reg  send_continuous_pkts_sync_d;
  wire send_continuous_pkts_sync;
pcs64_user_cdc_sync i_pcs64_core_send_continuous_pkts_syncer (
    .clk                 (tx_mii_clk),
    .signal_in           (send_continuous_pkts),
    .signal_out          (send_continuous_pkts_sync)
  );
assign time_out = ~|op_timer,
       done     = (state==S7);

always @( posedge tx_mii_clk  )
    begin
      if ( tx_mii_reset == 1'b1 ) begin
    tx_mii_d <= { 8 { 8'h07 }} ;
    tx_mii_c <= { 8 { 1'b1 }} ;

    state <= S0;
    q_en <= 0;
    rand1 <= init_crc;
    counter <= 0;
    d_buff <= 64'd0 ;
    d_sel <= 0;
    z_pkt <= 0;
    op_timer <= 30'd390625000 ;
    en_residue <= 0;
    packet_counter <= 0;
    set_eop <= 0;
    idle_cycle <= 'd0;
    bsy_cntr <= 0;
    send_continuous_pkts_sync_d <= 0;
  end
  else begin
    tx_mii_d <= { 8 { 8'h07 }} ;                // default to idle
    tx_mii_c <= { 8 { 1'b1 }} ;
    set_eop <= 0;

    if (send_continuous_pkts_sync)
      send_continuous_pkts_sync_d <= 1'b1;
    else if ( state == S7 )
      send_continuous_pkts_sync_d <= 1'b0;

    q_en <= {q_en, enable};

    header_bit_count <= 0;
    case(state)
      S0: if (q_en == 2'b01) state <= S1;
      S1: state <= S2;
      S2: begin
            packet_counter <= packet_count;
            rand1 <= init_crc;
            d_sel <= data_select;
            counter <= xfer_cnt;
            state <= S3;
          end
      S3: begin
            if (idle_cycle == 'd0) begin
            d_buff <= swapn(nxt_d);
            rand1 <= nxt_rand1;
            counter <= |counter ? counter - 1 : 0;
            z_pkt <= ~|counter;
            en_residue <= 0;
            state <= |packet_count ? S4 : S7;
            packet_counter <= &packet_counter ?  packet_counter : packet_counter-1;
            header_bit_count <= 9'd175 ;
            end else begin
              idle_cycle <= idle_cycle - 'd1;
            end
          end
      S4,S5: begin  :zulu
            reg [63:0] tx_datain;
            d_buff <= swapn(nxt_d);
            rand1 <= nxt_rand1;
            counter <= |counter ? counter - 1 : 0;
            z_pkt <= 0;
            header_bit_count <= header_bit_count[8] ? header_bit_count : header_bit_count - 64 ;
            if(~|counter && (xfer_rmdr==0) || z_pkt) end_packet;
            else begin
              tx_datain = op_data;
              if(!header_bit_count[8]) begin            // if there is some header left to send, then send it
                if(header_bit_count<63) tx_datain[63-:48] = eth_header[0+:48] ;
                else tx_datain = eth_header[header_bit_count-:64] ;
              end
              tx_mii_c <= { 8 { 1'b0 }} ;
              tx_mii_d <= swapn(tx_datain);
              if(state==S4) tx_mii_c[0] <= 1'b1;
              state <= |counter ? S5 : S6;
            end
            en_residue <= insert_crc && (counter==1) && (xfer_cnt != crc_cnt) && (crc_bits!= 0) ;
            if( en_residue ) begin
              tx_datain[0+:crc_residue_bits] = op_crc[crc_residue_start+:crc_residue_bits];
              tx_mii_d <= swapn(tx_datain);
            end
          end
      S6: end_packet;
      S7: state <= |q_en ? S7 : S0;

    endcase

    case(state)
      S0,S7:    op_timer <= 30'd390625000 ;
      S4,S5,S6: op_timer <= 30'd390625000 ;
      default:  op_timer <= |op_timer ? op_timer - 1 : op_timer ;
    endcase

    if(set_eop) begin tx_mii_d[0+:8] <= 8'hFD ; tx_mii_c[0] <= 1'b1; end
    if ( state <= S0 ) begin
      bsy_cntr <= |bsy_cntr ? bsy_cntr - 1 : bsy_cntr ;             // Hold the busy signal for 8 additional cycles.
      busy <= |bsy_cntr;
    end
    else begin
      busy <= 1'b1;
      bsy_cntr <= {3{1'b1}};
    end
  end
end

task end_packet;
reg [63:0]  tmp_dat;
begin
  tmp_dat = op_data & op_mask | ~op_mask & { 8 { 8'h07 }} ;
  if(insert_crc) tmp_dat[crc_insrt+:nz_bits] = op_crc[0+:nz_bits];

  tx_mii_d <= swapn ( tmp_dat ) ;
  tx_mii_c <= xfer_ctl ;

  rand1 <= init_crc;
  counter <= xfer_cnt;
  //state <= (|packet_counter && |q_en) ? S3 : S7;
  if(send_continuous_pkts_sync_d)
    state <= (send_continuous_pkts_sync) ? S3 : S7;
  else
  state <= (|packet_counter && |q_en) ? S3 : S7;
  set_eop <= (full_bits==0) ;
  idle_cycle <= 'd1;
  if(full_bits != 0 ) tx_mii_d[full_bits+:8] <= 8'hFD ;
end
endtask

function [31:0] gen_CRC_const ( input integer n, input const_data );
integer i,j;
reg [31:0] loc_poly;
begin
  loc_poly = {32{1'b1}};           // synthesis loop_limit 100000
  for(i=0; i<(n*8); i=i+1) begin
    if(i <= 111 ) loc_poly = ({33{(loc_poly[31] ^ eth_header[ crc_jiggle( 111 - i ) ])}} & CRC_POLYNOMIAL) ^ {loc_poly,1'b0};
    else                          loc_poly = ({33{(loc_poly[31] ^ const_data)}} & CRC_POLYNOMIAL) ^ {loc_poly,1'b0};
  end
  for(i=0;i<=31;i=i+1) gen_CRC_const[i] = ~loc_poly[{i[3+:2],~i[0+:3]}];
end
endfunction

function [31:0] gen_CRC3 ( input integer n );
integer i;
reg [31:0] dat_gen;
reg [31:0] loc_poly;
begin
  loc_poly = {32{1'b1}};
  dat_gen = init_crc;           // synthesis loop_limit 100000

  for(i=0; i<(n*8); i=i+1) begin
    dat_gen = {dat_gen,^(DATA_POLYNOMIAL & {dat_gen,1'b0})};
    if(i <= 111 ) loc_poly = ({33{(loc_poly[31] ^ eth_header[ crc_jiggle( 111 - i ) ])}} & CRC_POLYNOMIAL) ^ {loc_poly,1'b0};
    else                          loc_poly = ({33{(loc_poly[31] ^ dat_gen[0])}} & CRC_POLYNOMIAL) ^ {loc_poly,1'b0};
  end

  for(i=0;i<=31;i=i+1) gen_CRC3[i] = ~loc_poly[{i[3+:2],~i[0+:3]}];
end
endfunction

function integer  crc_jiggle ( input integer d );
crc_jiggle = { d[31:3], ~d[2:0] } ;
endfunction

function [63:0]  swapn (input [63:0]  d);
integer i;
for (i=0; i<=(63); i=i+8) swapn[i+:8] = d[(63-i)-:8];
endfunction

endmodule
module pcs64_mii_traf_chk (

  input wire mii_clk,
  input wire mii_reset,
  input wire enable,
  input wire clear_count,
  input wire sys_reset,

  input wire [63:0] mii_d,
  input wire [7:0]  mii_c,
  output wire  rx_reset,
//// RX Control Signals
  output wire ctl_rx_test_pattern,
  output wire ctl_rx_test_pattern_enable,
  output wire ctl_rx_data_pattern_select,
  output wire ctl_rx_prbs31_test_pattern_enable,


//// RX Stats Signals
  input  wire stat_rx_block_lock,
  input  wire stat_rx_framing_err_valid,
  input  wire stat_rx_framing_err,
  input  wire stat_rx_hi_ber,
  input  wire stat_rx_valid_ctrl_code,
  input  wire stat_rx_bad_code,
  input  wire stat_rx_bad_code_valid,
  input  wire stat_rx_error_valid,
  input  wire [7:0] stat_rx_error,
  input  wire stat_rx_fifo_error,
  input  wire stat_rx_local_fault,

  output reg protocol_error,
  output wire [47:0] packet_count,
  output wire [63:0] total_bytes,
  output wire [31:0] prot_err_count,
  output wire [31:0] error_count,
  output wire packet_count_overflow,
  output wire prot_err_overflow,
  output wire error_overflow,
  output wire total_bytes_overflow,
  output reg rx_gt_locked_led,
  output reg rx_block_lock_led

);

/* Parameter definitions of STATE variables for 1 bit state machine */

localparam [1:0]  S0 = 2'b00,
                  S1 = 2'b01,
                  S2 = 2'b11,
                  S3 = 2'b10;
reg [48:0] pct_cntr;
reg [32:0] perr_cntr, err_cntr;
wire       rx_block_lock;
reg        rx_gt_locked_led_1d;
reg        rx_gt_locked_led_2d;
reg        rx_gt_locked_led_3d;
reg        rx_block_lock_led_1d;
reg        rx_block_lock_led_2d;
reg        rx_block_lock_led_3d;
reg [1:0] state ;
reg [1:0] q_en;
reg [3:0] delta_bytes;
reg [3:0] ss_bytes;
reg [64:0] byte_cntr;
reg inc_pct_cntr;
reg inc_err_cntr;
wire ctl_rx_enable;
assign packet_count           = pct_cntr[48] ? {48{1'b1}} : pct_cntr[47:0],
       packet_count_overflow  = pct_cntr[48],
       prot_err_count         = perr_cntr[32] ? {32{1'b1}} : perr_cntr[31:0],
       prot_err_overflow      = perr_cntr[32],
       error_count            = err_cntr[32] ? {32{1'b1}} : err_cntr[31:0],
       error_overflow         = err_cntr[32],
       total_bytes            = byte_cntr[64] ? {64{1'b1}} : byte_cntr[63:0],
       total_bytes_overflow   = byte_cntr[64];

assign rx_reset                   = 1'b0;
assign rx_block_lock              = stat_rx_block_lock;

assign ctl_FEC_RX_Enable          = 1'b0;
assign ctl_rx_enable              = 1'b1;
assign ctl_rx_test_pattern        = 1'b0;
assign ctl_rx_data_pattern_select = 1'b0;
assign ctl_rx_test_pattern_enable = 1'b0;
assign ctl_rx_test_pattern_select = 1'b0;
assign ctl_rx_prbs31_test_pattern_enable  = 1'b0;

integer i;


always @( posedge mii_clk )
    begin
      if ( mii_reset == 1'b1 ) begin
    q_en <= 0;
    state <= S0;
    protocol_error <= 0;
    pct_cntr <= 49'h0;
    err_cntr <= 33'h0;
    perr_cntr <= 33'h0;
    byte_cntr <= 65'h0;
    inc_pct_cntr <= 0;
    inc_err_cntr <= 0;
    delta_bytes <= 0;
    ss_bytes <= 0;
  end
  else begin
    delta_bytes <= 0;
    ss_bytes <= 0;
    inc_pct_cntr <= 0;
    inc_err_cntr <= 0;
    protocol_error <= 0;
    q_en <= {q_en, enable};

    case (state)
      S0: if (q_en == 2'b01) state <= S1;
      S1: begin :start_check
            integer i;
            reg [3:0] byte_count;
            reg start_flag;
            start_flag = 0;
            byte_count = 4'd0;
            for(i=0; i<7;i=i+4) if( (mii_d[i*8+:8] == 8'hFB) && mii_c[i] ) begin start_flag = 1; byte_count = 8-i; end
            if( start_flag ) state <= S2;
            delta_bytes <= byte_count;
          end
      S2: begin :end_check
            integer i,j;
            reg [3:0] byte_count1,byte_count2;
            reg start_flag,end_flag;
            start_flag = 0;
            end_flag = 0;
            byte_count1 = 4'd8;
            byte_count2 = 4'd0;
            for(i=7;i>=0;i=i-1) if( (mii_d[i*8+:8] == 8'hFD) && mii_c[i] ) begin end_flag = 1; byte_count1 = i; end
            for(j=0; j<7;j=j+4) if( (mii_d[j*8+:8] == 8'hFB) && mii_c[j] ) begin start_flag = 1; byte_count2 = 8-j; end
            if( end_flag ) begin
              state <= S1;
              inc_pct_cntr <= 1'b1;
            end
            if( start_flag ) state <= S2;
            delta_bytes <= byte_count1;
            ss_bytes    <= byte_count2;
          end

      default: state <= S0;
    endcase

    if ( &q_en )  begin :error_check
      integer i;
      for(i=0; i<7;i=i+1) if( (mii_d[i*8+:8] == 8'hFE) && mii_c[i] ) inc_err_cntr <= 1;
    end


    if(~|q_en) state <= S0;
    if(!byte_cntr[64]) byte_cntr <= byte_cntr + {1'b0,delta_bytes} + {1'b0,ss_bytes};
    if(protocol_error && !perr_cntr[32]) perr_cntr <= perr_cntr + 1;
    if(inc_pct_cntr && !pct_cntr[48])  pct_cntr <= pct_cntr + 1;
    if(inc_err_cntr && !err_cntr[32]) err_cntr <= err_cntr + 1;
    if(clear_count)begin
      byte_cntr <= 65'h0;
      pct_cntr <= 49'h0;
      err_cntr <= 33'h0;
      perr_cntr <= 33'h0;
    end
  end
end

`ifdef SARANCE_RTL_DEBUG
// pragma translate_off
  reg [8*12-1:0] state_text;                    // Enumerated type conversion to text
  always @(state) case (state)
    S0: state_text = "S0" ;
    S1: state_text = "S1" ;
    S2: state_text = "S2" ;
    S3: state_text = "S3" ;
  endcase
`endif



   //////////////////////////////////////////////////
    ////Registering the LED ports
    //////////////////////////////////////////////////

    always @( posedge mii_clk )
    begin
        if ( mii_reset == 1'b1 )
        begin
            rx_gt_locked_led_1d     <= 1'b0;
            rx_gt_locked_led_2d     <= 1'b0;
            rx_gt_locked_led_3d     <= 1'b0;
            rx_block_lock_led_1d    <= 1'b0;
            rx_block_lock_led_2d    <= 1'b0;
            rx_block_lock_led_3d    <= 1'b0;
        end
        else
        begin
            rx_gt_locked_led_1d     <= ~mii_reset;
            rx_gt_locked_led_2d     <= rx_gt_locked_led_1d;
            rx_gt_locked_led_3d     <= rx_gt_locked_led_2d;
            rx_block_lock_led_1d    <= rx_block_lock;
            rx_block_lock_led_2d    <= rx_block_lock_led_1d;
            rx_block_lock_led_3d    <= rx_block_lock_led_2d;
        end
    end

   //////////////////////////////////////////////////
    ////Assign RX LED Output ports with ASYN sys_reset
    //////////////////////////////////////////////////
    always @( posedge mii_clk, posedge sys_reset  )
    begin
        if ( sys_reset == 1'b1 )
        begin
            rx_gt_locked_led     <= 1'b0;
            rx_block_lock_led    <= 1'b0;
        end
        else
        begin
            rx_gt_locked_led     <= rx_gt_locked_led_3d;
            rx_block_lock_led    <= rx_block_lock_led_3d;
        end
    end


endmodule
module pcs64_mii_traf_gen_chk (

  input wire mii_clk,
  input wire mii_reset,
  input wire enable,
  input wire clear_count,

  input wire [63:0] mii_d,
  input wire [7:0]  mii_c,


  output reg protocol_error,
  output wire [47:0] packet_count,
  output wire [63:0] total_bytes,
  output wire [31:0] prot_err_count,
  output wire [31:0] error_count,
  output wire packet_count_overflow,
  output wire prot_err_overflow,
  output wire error_overflow,
  output wire total_bytes_overflow
);

/* Parameter definitions of STATE variables for 1 bit state machine */
localparam [1:0]  S0 = 2'b00,
                  S1 = 2'b01,
                  S2 = 2'b11,
                  S3 = 2'b10;
reg [48:0] pct_cntr;
reg [32:0] perr_cntr, err_cntr;

reg [1:0] state ;
reg [1:0] q_en;
reg [3:0] delta_bytes;
reg [3:0] ss_bytes;
(* keep = "true" *) reg [64:0] byte_cntr;
reg inc_pct_cntr;
reg inc_err_cntr;

assign packet_count           = pct_cntr[48] ? {48{1'b1}} : pct_cntr[47:0],
       packet_count_overflow  = pct_cntr[48],
       prot_err_count         = perr_cntr[32] ? {32{1'b1}} : perr_cntr[31:0],
       prot_err_overflow      = perr_cntr[32],
       error_count            = err_cntr[32] ? {32{1'b1}} : err_cntr[31:0],
       error_overflow         = err_cntr[32],
       total_bytes            = byte_cntr[64] ? {64{1'b1}} : byte_cntr[63:0],
       total_bytes_overflow   = byte_cntr[64];

integer i;
always @( posedge mii_clk )
    begin
      if ( mii_reset == 1'b1 ) begin
    q_en <= 0;
    state <= S0;
    protocol_error <= 0;
    pct_cntr <= 49'h0;
    err_cntr <= 33'h0;
    perr_cntr <= 33'h0;
    byte_cntr <= 65'h0;
    inc_pct_cntr <= 0;
    inc_err_cntr <= 0;
    delta_bytes <= 0;
    ss_bytes <= 0;
  end
  else begin
    delta_bytes <= 0;
    ss_bytes <= 0;
    inc_pct_cntr <= 0;
    inc_err_cntr <= 0;
    protocol_error <= 0;
    q_en <= {q_en, enable};

    case (state)
      S0: if (q_en == 2'b01) state <= S1;
      S1: begin :start_check
            integer i;
            reg [3:0] byte_count;
            reg start_flag;
            start_flag = 0;
            byte_count = 4'd0;
            for(i=0; i<7;i=i+4) if( (mii_d[i*8+:8] == 8'hFB) && mii_c[i] ) begin start_flag = 1; byte_count = 8-i; end
            if( start_flag ) state <= S2;
            delta_bytes <= byte_count;
          end
      S2: begin :end_check
            integer i,j;
            reg [3:0] byte_count1,byte_count2;
            reg start_flag,end_flag;
            start_flag = 0;
            end_flag = 0;
            byte_count1 = 4'd8;
            byte_count2 = 4'd0;
            for(i=7;i>=0;i=i-1) if( (mii_d[i*8+:8] == 8'hFD) && mii_c[i] ) begin end_flag = 1; byte_count1 = i; end
            for(j=0; j<7;j=j+4) if( (mii_d[j*8+:8] == 8'hFB) && mii_c[j] ) begin start_flag = 1; byte_count2 = 8-j; end
            if( end_flag ) begin
              state <= S1;
              inc_pct_cntr <= 1'b1;
            end
            if( start_flag ) state <= S2;
            delta_bytes <= byte_count1;
            ss_bytes    <= byte_count2;
          end

      default: state <= S0;
    endcase

    if ( &q_en )  begin :error_check
      integer i;
      for(i=0; i<7;i=i+1) if( (mii_d[i*8+:8] == 8'hFE) && mii_c[i] ) inc_err_cntr <= 1;
    end


    if(~|q_en) state <= S0;
    if(!byte_cntr[64]) byte_cntr <= byte_cntr + {1'b0,delta_bytes} + {1'b0,ss_bytes};
    if(protocol_error && !perr_cntr[32]) perr_cntr <= perr_cntr + 1;
    if(inc_pct_cntr && !pct_cntr[48])  pct_cntr <= pct_cntr + 1;
    if(inc_err_cntr && !err_cntr[32]) err_cntr <= err_cntr + 1;
    if(clear_count)begin
      byte_cntr <= 65'h0;
      pct_cntr <= 49'h0;
      err_cntr <= 33'h0;
      perr_cntr <= 33'h0;
    end
  end
end

`ifdef SARANCE_RTL_DEBUG
// pragma translate_off
  reg [8*12-1:0] state_text;                    // Enumerated type conversion to text
  always @(state) case (state)
    S0: state_text = "S0" ;
    S1: state_text = "S1" ;
    S2: state_text = "S2" ;
    S3: state_text = "S3" ;
  endcase
`endif

endmodule
module pcs64_pcs_pktprbs_gen
 #(
  parameter BIT_COUNT = 64
) (
  input   wire [31:0] ip,
  output  wire [31:0] op,
  output  wire [(BIT_COUNT-1):0] datout
);
//     G(x) = x32 + x27 + x21 + x19 + x10 + x7 + 1
localparam [32:0] CRC_POLYNOMIAL = 33'b100001000001010000000010010000001;

localparam REMAINDER_SIZE = 32;

generate

case (BIT_COUNT)

  512: begin :gen_512_loop

          assign op[0] = ip[0]^ip[1]^ip[3]^ip[5]^ip[6]^ip[9]^ip[14]^ip[15]^ip[16]^ip[17]^ip[18]^ip[22]^ip[24]^ip[27]^ip[30]^ip[31],
                 op[1] = ip[0]^ip[1]^ip[2]^ip[4]^ip[6]^ip[15]^ip[16]^ip[17]^ip[18]^ip[21]^ip[23]^ip[25]^ip[27]^ip[28]^ip[31],
                 op[2] = ip[0]^ip[1]^ip[2]^ip[3]^ip[5]^ip[10]^ip[16]^ip[17]^ip[18]^ip[21]^ip[22]^ip[24]^ip[26]^ip[27]^ip[28]^ip[29],
                 op[3] = ip[1]^ip[2]^ip[3]^ip[4]^ip[6]^ip[11]^ip[17]^ip[18]^ip[19]^ip[22]^ip[23]^ip[25]^ip[27]^ip[28]^ip[29]^ip[30],
                 op[4] = ip[2]^ip[3]^ip[4]^ip[5]^ip[7]^ip[12]^ip[18]^ip[19]^ip[20]^ip[23]^ip[24]^ip[26]^ip[28]^ip[29]^ip[30]^ip[31],
                 op[5] = ip[0]^ip[3]^ip[4]^ip[5]^ip[6]^ip[7]^ip[8]^ip[10]^ip[13]^ip[20]^ip[24]^ip[25]^ip[29]^ip[30]^ip[31],
                 op[6] = ip[0]^ip[1]^ip[4]^ip[5]^ip[6]^ip[8]^ip[9]^ip[10]^ip[11]^ip[14]^ip[19]^ip[25]^ip[26]^ip[27]^ip[30]^ip[31],
                 op[7] = ip[0]^ip[1]^ip[2]^ip[5]^ip[6]^ip[9]^ip[11]^ip[12]^ip[15]^ip[19]^ip[20]^ip[21]^ip[26]^ip[28]^ip[31],
                 op[8] = ip[0]^ip[1]^ip[2]^ip[3]^ip[6]^ip[12]^ip[13]^ip[16]^ip[19]^ip[20]^ip[22]^ip[29],
                 op[9] = ip[1]^ip[2]^ip[3]^ip[4]^ip[7]^ip[13]^ip[14]^ip[17]^ip[20]^ip[21]^ip[23]^ip[30],
                 op[10] = ip[2]^ip[3]^ip[4]^ip[5]^ip[8]^ip[14]^ip[15]^ip[18]^ip[21]^ip[22]^ip[24]^ip[31],
                 op[11] = ip[0]^ip[3]^ip[4]^ip[5]^ip[6]^ip[7]^ip[9]^ip[10]^ip[15]^ip[16]^ip[21]^ip[22]^ip[23]^ip[25]^ip[27],
                 op[12] = ip[1]^ip[4]^ip[5]^ip[6]^ip[7]^ip[8]^ip[10]^ip[11]^ip[16]^ip[17]^ip[22]^ip[23]^ip[24]^ip[26]^ip[28],
                 op[13] = ip[2]^ip[5]^ip[6]^ip[7]^ip[8]^ip[9]^ip[11]^ip[12]^ip[17]^ip[18]^ip[23]^ip[24]^ip[25]^ip[27]^ip[29],
                 op[14] = ip[3]^ip[6]^ip[7]^ip[8]^ip[9]^ip[10]^ip[12]^ip[13]^ip[18]^ip[19]^ip[24]^ip[25]^ip[26]^ip[28]^ip[30],
                 op[15] = ip[4]^ip[7]^ip[8]^ip[9]^ip[10]^ip[11]^ip[13]^ip[14]^ip[19]^ip[20]^ip[25]^ip[26]^ip[27]^ip[29]^ip[31],
                 op[16] = ip[0]^ip[5]^ip[7]^ip[8]^ip[9]^ip[11]^ip[12]^ip[14]^ip[15]^ip[19]^ip[20]^ip[26]^ip[28]^ip[30],
                 op[17] = ip[1]^ip[6]^ip[8]^ip[9]^ip[10]^ip[12]^ip[13]^ip[15]^ip[16]^ip[20]^ip[21]^ip[27]^ip[29]^ip[31],
                 op[18] = ip[0]^ip[2]^ip[9]^ip[11]^ip[13]^ip[14]^ip[16]^ip[17]^ip[19]^ip[22]^ip[27]^ip[28]^ip[30],
                 op[19] = ip[1]^ip[3]^ip[10]^ip[12]^ip[14]^ip[15]^ip[17]^ip[18]^ip[20]^ip[23]^ip[28]^ip[29]^ip[31],
                 op[20] = ip[0]^ip[2]^ip[4]^ip[7]^ip[10]^ip[11]^ip[13]^ip[15]^ip[16]^ip[18]^ip[24]^ip[27]^ip[29]^ip[30],
                 op[21] = ip[1]^ip[3]^ip[5]^ip[8]^ip[11]^ip[12]^ip[14]^ip[16]^ip[17]^ip[19]^ip[25]^ip[28]^ip[30]^ip[31],
                 op[22] = ip[0]^ip[2]^ip[4]^ip[6]^ip[7]^ip[9]^ip[10]^ip[12]^ip[13]^ip[15]^ip[17]^ip[18]^ip[19]^ip[20]^ip[21]^ip[26]^ip[27]^ip[29]^ip[31],
                 op[23] = ip[0]^ip[1]^ip[3]^ip[5]^ip[8]^ip[11]^ip[13]^ip[14]^ip[16]^ip[18]^ip[20]^ip[22]^ip[28]^ip[30],
                 op[24] = ip[1]^ip[2]^ip[4]^ip[6]^ip[9]^ip[12]^ip[14]^ip[15]^ip[17]^ip[19]^ip[21]^ip[23]^ip[29]^ip[31],
                 op[25] = ip[0]^ip[2]^ip[3]^ip[5]^ip[13]^ip[15]^ip[16]^ip[18]^ip[19]^ip[20]^ip[21]^ip[22]^ip[24]^ip[27]^ip[30],
                 op[26] = ip[1]^ip[3]^ip[4]^ip[6]^ip[14]^ip[16]^ip[17]^ip[19]^ip[20]^ip[21]^ip[22]^ip[23]^ip[25]^ip[28]^ip[31],
                 op[27] = ip[0]^ip[2]^ip[4]^ip[5]^ip[10]^ip[15]^ip[17]^ip[18]^ip[19]^ip[20]^ip[22]^ip[23]^ip[24]^ip[26]^ip[27]^ip[29],
                 op[28] = ip[1]^ip[3]^ip[5]^ip[6]^ip[11]^ip[16]^ip[18]^ip[19]^ip[20]^ip[21]^ip[23]^ip[24]^ip[25]^ip[27]^ip[28]^ip[30],
                 op[29] = ip[2]^ip[4]^ip[6]^ip[7]^ip[12]^ip[17]^ip[19]^ip[20]^ip[21]^ip[22]^ip[24]^ip[25]^ip[26]^ip[28]^ip[29]^ip[31],
                 op[30] = ip[0]^ip[3]^ip[5]^ip[8]^ip[10]^ip[13]^ip[18]^ip[19]^ip[20]^ip[22]^ip[23]^ip[25]^ip[26]^ip[29]^ip[30],
                 op[31] = ip[1]^ip[4]^ip[6]^ip[9]^ip[11]^ip[14]^ip[19]^ip[20]^ip[21]^ip[23]^ip[24]^ip[26]^ip[27]^ip[30]^ip[31];

          assign datout[0] = ip[6]^ip[9]^ip[18]^ip[20]^ip[26]^ip[31],
                 datout[1] = ip[5]^ip[8]^ip[17]^ip[19]^ip[25]^ip[30],
                 datout[2] = ip[4]^ip[7]^ip[16]^ip[18]^ip[24]^ip[29],
                 datout[3] = ip[3]^ip[6]^ip[15]^ip[17]^ip[23]^ip[28],
                 datout[4] = ip[2]^ip[5]^ip[14]^ip[16]^ip[22]^ip[27],
                 datout[5] = ip[1]^ip[4]^ip[13]^ip[15]^ip[21]^ip[26],
                 datout[6] = ip[0]^ip[3]^ip[12]^ip[14]^ip[20]^ip[25],
                 datout[7] = ip[2]^ip[6]^ip[9]^ip[11]^ip[13]^ip[18]^ip[19]^ip[20]^ip[24]^ip[26]^ip[31],
                 datout[8] = ip[1]^ip[5]^ip[8]^ip[10]^ip[12]^ip[17]^ip[18]^ip[19]^ip[23]^ip[25]^ip[30],
                 datout[9] = ip[0]^ip[4]^ip[7]^ip[9]^ip[11]^ip[16]^ip[17]^ip[18]^ip[22]^ip[24]^ip[29],
                 datout[10] = ip[3]^ip[8]^ip[9]^ip[10]^ip[15]^ip[16]^ip[17]^ip[18]^ip[20]^ip[21]^ip[23]^ip[26]^ip[28]^ip[31],
                 datout[11] = ip[2]^ip[7]^ip[8]^ip[9]^ip[14]^ip[15]^ip[16]^ip[17]^ip[19]^ip[20]^ip[22]^ip[25]^ip[27]^ip[30],
                 datout[12] = ip[1]^ip[6]^ip[7]^ip[8]^ip[13]^ip[14]^ip[15]^ip[16]^ip[18]^ip[19]^ip[21]^ip[24]^ip[26]^ip[29],
                 datout[13] = ip[0]^ip[5]^ip[6]^ip[7]^ip[12]^ip[13]^ip[14]^ip[15]^ip[17]^ip[18]^ip[20]^ip[23]^ip[25]^ip[28],
                 datout[14] = ip[4]^ip[5]^ip[9]^ip[11]^ip[12]^ip[13]^ip[14]^ip[16]^ip[17]^ip[18]^ip[19]^ip[20]^ip[22]^ip[24]^ip[26]^ip[27]^ip[31],
                 datout[15] = ip[3]^ip[4]^ip[8]^ip[10]^ip[11]^ip[12]^ip[13]^ip[15]^ip[16]^ip[17]^ip[18]^ip[19]^ip[21]^ip[23]^ip[25]^ip[26]^ip[30],
                 datout[16] = ip[2]^ip[3]^ip[7]^ip[9]^ip[10]^ip[11]^ip[12]^ip[14]^ip[15]^ip[16]^ip[17]^ip[18]^ip[20]^ip[22]^ip[24]^ip[25]^ip[29],
                 datout[17] = ip[1]^ip[2]^ip[6]^ip[8]^ip[9]^ip[10]^ip[11]^ip[13]^ip[14]^ip[15]^ip[16]^ip[17]^ip[19]^ip[21]^ip[23]^ip[24]^ip[28],
                 datout[18] = ip[0]^ip[1]^ip[5]^ip[7]^ip[8]^ip[9]^ip[10]^ip[12]^ip[13]^ip[14]^ip[15]^ip[16]^ip[18]^ip[20]^ip[22]^ip[23]^ip[27],
                 datout[19] = ip[0]^ip[4]^ip[7]^ip[8]^ip[11]^ip[12]^ip[13]^ip[14]^ip[15]^ip[17]^ip[18]^ip[19]^ip[20]^ip[21]^ip[22]^ip[31],
                 datout[20] = ip[3]^ip[7]^ip[9]^ip[10]^ip[11]^ip[12]^ip[13]^ip[14]^ip[16]^ip[17]^ip[19]^ip[21]^ip[26]^ip[30]^ip[31],
                 datout[21] = ip[2]^ip[6]^ip[8]^ip[9]^ip[10]^ip[11]^ip[12]^ip[13]^ip[15]^ip[16]^ip[18]^ip[20]^ip[25]^ip[29]^ip[30],
                 datout[22] = ip[1]^ip[5]^ip[7]^ip[8]^ip[9]^ip[10]^ip[11]^ip[12]^ip[14]^ip[15]^ip[17]^ip[19]^ip[24]^ip[28]^ip[29],
                 datout[23] = ip[0]^ip[4]^ip[6]^ip[7]^ip[8]^ip[9]^ip[10]^ip[11]^ip[13]^ip[14]^ip[16]^ip[18]^ip[23]^ip[27]^ip[28],
                 datout[24] = ip[3]^ip[5]^ip[7]^ip[8]^ip[10]^ip[12]^ip[13]^ip[15]^ip[17]^ip[18]^ip[20]^ip[22]^ip[27]^ip[31],
                 datout[25] = ip[2]^ip[4]^ip[6]^ip[7]^ip[9]^ip[11]^ip[12]^ip[14]^ip[16]^ip[17]^ip[19]^ip[21]^ip[26]^ip[30],
                 datout[26] = ip[1]^ip[3]^ip[5]^ip[6]^ip[8]^ip[10]^ip[11]^ip[13]^ip[15]^ip[16]^ip[18]^ip[20]^ip[25]^ip[29],
                 datout[27] = ip[0]^ip[2]^ip[4]^ip[5]^ip[7]^ip[9]^ip[10]^ip[12]^ip[14]^ip[15]^ip[17]^ip[19]^ip[24]^ip[28],
                 datout[28] = ip[1]^ip[3]^ip[4]^ip[8]^ip[11]^ip[13]^ip[14]^ip[16]^ip[20]^ip[23]^ip[26]^ip[27]^ip[31],
                 datout[29] = ip[0]^ip[2]^ip[3]^ip[7]^ip[10]^ip[12]^ip[13]^ip[15]^ip[19]^ip[22]^ip[25]^ip[26]^ip[30],
                 datout[30] = ip[1]^ip[2]^ip[11]^ip[12]^ip[14]^ip[20]^ip[21]^ip[24]^ip[25]^ip[26]^ip[29]^ip[31],
                 datout[31] = ip[0]^ip[1]^ip[10]^ip[11]^ip[13]^ip[19]^ip[20]^ip[23]^ip[24]^ip[25]^ip[28]^ip[30],
                 datout[32] = ip[0]^ip[6]^ip[10]^ip[12]^ip[19]^ip[20]^ip[22]^ip[23]^ip[24]^ip[26]^ip[27]^ip[29]^ip[31],
                 datout[33] = ip[5]^ip[6]^ip[11]^ip[19]^ip[20]^ip[21]^ip[22]^ip[23]^ip[25]^ip[28]^ip[30]^ip[31],
                 datout[34] = ip[4]^ip[5]^ip[10]^ip[18]^ip[19]^ip[20]^ip[21]^ip[22]^ip[24]^ip[27]^ip[29]^ip[30],
                 datout[35] = ip[3]^ip[4]^ip[9]^ip[17]^ip[18]^ip[19]^ip[20]^ip[21]^ip[23]^ip[26]^ip[28]^ip[29],
                 datout[36] = ip[2]^ip[3]^ip[8]^ip[16]^ip[17]^ip[18]^ip[19]^ip[20]^ip[22]^ip[25]^ip[27]^ip[28],
                 datout[37] = ip[1]^ip[2]^ip[7]^ip[15]^ip[16]^ip[17]^ip[18]^ip[19]^ip[21]^ip[24]^ip[26]^ip[27],
                 datout[38] = ip[0]^ip[1]^ip[6]^ip[14]^ip[15]^ip[16]^ip[17]^ip[18]^ip[20]^ip[23]^ip[25]^ip[26],
                 datout[39] = ip[0]^ip[5]^ip[6]^ip[9]^ip[13]^ip[14]^ip[15]^ip[16]^ip[17]^ip[18]^ip[19]^ip[20]^ip[22]^ip[24]^ip[25]^ip[26]^ip[31],
                 datout[40] = ip[4]^ip[5]^ip[6]^ip[8]^ip[9]^ip[12]^ip[13]^ip[14]^ip[15]^ip[16]^ip[17]^ip[19]^ip[20]^ip[21]^ip[23]^ip[24]^ip[25]^ip[26]^ip[30]^ip[31],
                 datout[41] = ip[3]^ip[4]^ip[5]^ip[7]^ip[8]^ip[11]^ip[12]^ip[13]^ip[14]^ip[15]^ip[16]^ip[18]^ip[19]^ip[20]^ip[22]^ip[23]^ip[24]^ip[25]^ip[29]^ip[30],
                 datout[42] = ip[2]^ip[3]^ip[4]^ip[6]^ip[7]^ip[10]^ip[11]^ip[12]^ip[13]^ip[14]^ip[15]^ip[17]^ip[18]^ip[19]^ip[21]^ip[22]^ip[23]^ip[24]^ip[28]^ip[29],
                 datout[43] = ip[1]^ip[2]^ip[3]^ip[5]^ip[6]^ip[9]^ip[10]^ip[11]^ip[12]^ip[13]^ip[14]^ip[16]^ip[17]^ip[18]^ip[20]^ip[21]^ip[22]^ip[23]^ip[27]^ip[28],
                 datout[44] = ip[0]^ip[1]^ip[2]^ip[4]^ip[5]^ip[8]^ip[9]^ip[10]^ip[11]^ip[12]^ip[13]^ip[15]^ip[16]^ip[17]^ip[19]^ip[20]^ip[21]^ip[22]^ip[26]^ip[27],
                 datout[45] = ip[0]^ip[1]^ip[3]^ip[4]^ip[6]^ip[7]^ip[8]^ip[10]^ip[11]^ip[12]^ip[14]^ip[15]^ip[16]^ip[19]^ip[21]^ip[25]^ip[31],
                 datout[46] = ip[0]^ip[2]^ip[3]^ip[5]^ip[7]^ip[10]^ip[11]^ip[13]^ip[14]^ip[15]^ip[24]^ip[26]^ip[30]^ip[31],
                 datout[47] = ip[1]^ip[2]^ip[4]^ip[10]^ip[12]^ip[13]^ip[14]^ip[18]^ip[20]^ip[23]^ip[25]^ip[26]^ip[29]^ip[30]^ip[31],
                 datout[48] = ip[0]^ip[1]^ip[3]^ip[9]^ip[11]^ip[12]^ip[13]^ip[17]^ip[19]^ip[22]^ip[24]^ip[25]^ip[28]^ip[29]^ip[30],
                 datout[49] = ip[0]^ip[2]^ip[6]^ip[8]^ip[9]^ip[10]^ip[11]^ip[12]^ip[16]^ip[20]^ip[21]^ip[23]^ip[24]^ip[26]^ip[27]^ip[28]^ip[29]^ip[31],
                 datout[50] = ip[1]^ip[5]^ip[6]^ip[7]^ip[8]^ip[10]^ip[11]^ip[15]^ip[18]^ip[19]^ip[22]^ip[23]^ip[25]^ip[27]^ip[28]^ip[30]^ip[31],
                 datout[51] = ip[0]^ip[4]^ip[5]^ip[6]^ip[7]^ip[9]^ip[10]^ip[14]^ip[17]^ip[18]^ip[21]^ip[22]^ip[24]^ip[26]^ip[27]^ip[29]^ip[30],
                 datout[52] = ip[3]^ip[4]^ip[5]^ip[8]^ip[13]^ip[16]^ip[17]^ip[18]^ip[21]^ip[23]^ip[25]^ip[28]^ip[29]^ip[31],
                 datout[53] = ip[2]^ip[3]^ip[4]^ip[7]^ip[12]^ip[15]^ip[16]^ip[17]^ip[20]^ip[22]^ip[24]^ip[27]^ip[28]^ip[30],
                 datout[54] = ip[1]^ip[2]^ip[3]^ip[6]^ip[11]^ip[14]^ip[15]^ip[16]^ip[19]^ip[21]^ip[23]^ip[26]^ip[27]^ip[29],
                 datout[55] = ip[0]^ip[1]^ip[2]^ip[5]^ip[10]^ip[13]^ip[14]^ip[15]^ip[18]^ip[20]^ip[22]^ip[25]^ip[26]^ip[28],
                 datout[56] = ip[0]^ip[1]^ip[4]^ip[6]^ip[12]^ip[13]^ip[14]^ip[17]^ip[18]^ip[19]^ip[20]^ip[21]^ip[24]^ip[25]^ip[26]^ip[27]^ip[31],
                 datout[57] = ip[0]^ip[3]^ip[5]^ip[6]^ip[9]^ip[11]^ip[12]^ip[13]^ip[16]^ip[17]^ip[19]^ip[23]^ip[24]^ip[25]^ip[30]^ip[31],
                 datout[58] = ip[2]^ip[4]^ip[5]^ip[6]^ip[8]^ip[9]^ip[10]^ip[11]^ip[12]^ip[15]^ip[16]^ip[20]^ip[22]^ip[23]^ip[24]^ip[26]^ip[29]^ip[30]^ip[31],
                 datout[59] = ip[1]^ip[3]^ip[4]^ip[5]^ip[7]^ip[8]^ip[9]^ip[10]^ip[11]^ip[14]^ip[15]^ip[19]^ip[21]^ip[22]^ip[23]^ip[25]^ip[28]^ip[29]^ip[30],
                 datout[60] = ip[0]^ip[2]^ip[3]^ip[4]^ip[6]^ip[7]^ip[8]^ip[9]^ip[10]^ip[13]^ip[14]^ip[18]^ip[20]^ip[21]^ip[22]^ip[24]^ip[27]^ip[28]^ip[29],
                 datout[61] = ip[1]^ip[2]^ip[3]^ip[5]^ip[7]^ip[8]^ip[12]^ip[13]^ip[17]^ip[18]^ip[19]^ip[21]^ip[23]^ip[27]^ip[28]^ip[31],
                 datout[62] = ip[0]^ip[1]^ip[2]^ip[4]^ip[6]^ip[7]^ip[11]^ip[12]^ip[16]^ip[17]^ip[18]^ip[20]^ip[22]^ip[26]^ip[27]^ip[30],
                 datout[63] = ip[0]^ip[1]^ip[3]^ip[5]^ip[9]^ip[10]^ip[11]^ip[15]^ip[16]^ip[17]^ip[18]^ip[19]^ip[20]^ip[21]^ip[25]^ip[29]^ip[31],
                 datout[64] = ip[0]^ip[2]^ip[4]^ip[6]^ip[8]^ip[10]^ip[14]^ip[15]^ip[16]^ip[17]^ip[19]^ip[24]^ip[26]^ip[28]^ip[30]^ip[31],
                 datout[65] = ip[1]^ip[3]^ip[5]^ip[6]^ip[7]^ip[13]^ip[14]^ip[15]^ip[16]^ip[20]^ip[23]^ip[25]^ip[26]^ip[27]^ip[29]^ip[30]^ip[31],
                 datout[66] = ip[0]^ip[2]^ip[4]^ip[5]^ip[6]^ip[12]^ip[13]^ip[14]^ip[15]^ip[19]^ip[22]^ip[24]^ip[25]^ip[26]^ip[28]^ip[29]^ip[30],
                 datout[67] = ip[1]^ip[3]^ip[4]^ip[5]^ip[6]^ip[9]^ip[11]^ip[12]^ip[13]^ip[14]^ip[20]^ip[21]^ip[23]^ip[24]^ip[25]^ip[26]^ip[27]^ip[28]^ip[29]^ip[31],
                 datout[68] = ip[0]^ip[2]^ip[3]^ip[4]^ip[5]^ip[8]^ip[10]^ip[11]^ip[12]^ip[13]^ip[19]^ip[20]^ip[22]^ip[23]^ip[24]^ip[25]^ip[26]^ip[27]^ip[28]^ip[30],
                 datout[69] = ip[1]^ip[2]^ip[3]^ip[4]^ip[6]^ip[7]^ip[10]^ip[11]^ip[12]^ip[19]^ip[20]^ip[21]^ip[22]^ip[23]^ip[24]^ip[25]^ip[27]^ip[29]^ip[31],
                 datout[70] = ip[0]^ip[1]^ip[2]^ip[3]^ip[5]^ip[6]^ip[9]^ip[10]^ip[11]^ip[18]^ip[19]^ip[20]^ip[21]^ip[22]^ip[23]^ip[24]^ip[26]^ip[28]^ip[30],
                 datout[71] = ip[0]^ip[1]^ip[2]^ip[4]^ip[5]^ip[6]^ip[8]^ip[10]^ip[17]^ip[19]^ip[21]^ip[22]^ip[23]^ip[25]^ip[26]^ip[27]^ip[29]^ip[31],
                 datout[72] = ip[0]^ip[1]^ip[3]^ip[4]^ip[5]^ip[6]^ip[7]^ip[16]^ip[21]^ip[22]^ip[24]^ip[25]^ip[28]^ip[30]^ip[31],
                 datout[73] = ip[0]^ip[2]^ip[3]^ip[4]^ip[5]^ip[9]^ip[15]^ip[18]^ip[21]^ip[23]^ip[24]^ip[26]^ip[27]^ip[29]^ip[30]^ip[31],
                 datout[74] = ip[1]^ip[2]^ip[3]^ip[4]^ip[6]^ip[8]^ip[9]^ip[14]^ip[17]^ip[18]^ip[22]^ip[23]^ip[25]^ip[28]^ip[29]^ip[30]^ip[31],
                 datout[75] = ip[0]^ip[1]^ip[2]^ip[3]^ip[5]^ip[7]^ip[8]^ip[13]^ip[16]^ip[17]^ip[21]^ip[22]^ip[24]^ip[27]^ip[28]^ip[29]^ip[30],
                 datout[76] = ip[0]^ip[1]^ip[2]^ip[4]^ip[7]^ip[9]^ip[12]^ip[15]^ip[16]^ip[18]^ip[21]^ip[23]^ip[27]^ip[28]^ip[29]^ip[31],
                 datout[77] = ip[0]^ip[1]^ip[3]^ip[8]^ip[9]^ip[11]^ip[14]^ip[15]^ip[17]^ip[18]^ip[22]^ip[27]^ip[28]^ip[30]^ip[31],
                 datout[78] = ip[0]^ip[2]^ip[6]^ip[7]^ip[8]^ip[9]^ip[10]^ip[13]^ip[14]^ip[16]^ip[17]^ip[18]^ip[20]^ip[21]^ip[27]^ip[29]^ip[30]^ip[31],
                 datout[79] = ip[1]^ip[5]^ip[7]^ip[8]^ip[12]^ip[13]^ip[15]^ip[16]^ip[17]^ip[18]^ip[19]^ip[28]^ip[29]^ip[30]^ip[31],
                 datout[80] = ip[0]^ip[4]^ip[6]^ip[7]^ip[11]^ip[12]^ip[14]^ip[15]^ip[16]^ip[17]^ip[18]^ip[27]^ip[28]^ip[29]^ip[30],
                 datout[81] = ip[3]^ip[5]^ip[9]^ip[10]^ip[11]^ip[13]^ip[14]^ip[15]^ip[16]^ip[17]^ip[18]^ip[20]^ip[27]^ip[28]^ip[29]^ip[31],
                 datout[82] = ip[2]^ip[4]^ip[8]^ip[9]^ip[10]^ip[12]^ip[13]^ip[14]^ip[15]^ip[16]^ip[17]^ip[19]^ip[26]^ip[27]^ip[28]^ip[30],
                 datout[83] = ip[1]^ip[3]^ip[7]^ip[8]^ip[9]^ip[11]^ip[12]^ip[13]^ip[14]^ip[15]^ip[16]^ip[18]^ip[25]^ip[26]^ip[27]^ip[29],
                 datout[84] = ip[0]^ip[2]^ip[6]^ip[7]^ip[8]^ip[10]^ip[11]^ip[12]^ip[13]^ip[14]^ip[15]^ip[17]^ip[24]^ip[25]^ip[26]^ip[28],
                 datout[85] = ip[1]^ip[5]^ip[7]^ip[10]^ip[11]^ip[12]^ip[13]^ip[14]^ip[16]^ip[18]^ip[20]^ip[23]^ip[24]^ip[25]^ip[26]^ip[27]^ip[31],
                 datout[86] = ip[0]^ip[4]^ip[6]^ip[9]^ip[10]^ip[11]^ip[12]^ip[13]^ip[15]^ip[17]^ip[19]^ip[22]^ip[23]^ip[24]^ip[25]^ip[26]^ip[30],
                 datout[87] = ip[3]^ip[5]^ip[6]^ip[8]^ip[10]^ip[11]^ip[12]^ip[14]^ip[16]^ip[20]^ip[21]^ip[22]^ip[23]^ip[24]^ip[25]^ip[26]^ip[29]^ip[31],
                 datout[88] = ip[2]^ip[4]^ip[5]^ip[7]^ip[9]^ip[10]^ip[11]^ip[13]^ip[15]^ip[19]^ip[20]^ip[21]^ip[22]^ip[23]^ip[24]^ip[25]^ip[28]^ip[30],
                 datout[89] = ip[1]^ip[3]^ip[4]^ip[6]^ip[8]^ip[9]^ip[10]^ip[12]^ip[14]^ip[18]^ip[19]^ip[20]^ip[21]^ip[22]^ip[23]^ip[24]^ip[27]^ip[29],
                 datout[90] = ip[0]^ip[2]^ip[3]^ip[5]^ip[7]^ip[8]^ip[9]^ip[11]^ip[13]^ip[17]^ip[18]^ip[19]^ip[20]^ip[21]^ip[22]^ip[23]^ip[26]^ip[28],
                 datout[91] = ip[1]^ip[2]^ip[4]^ip[7]^ip[8]^ip[9]^ip[10]^ip[12]^ip[16]^ip[17]^ip[19]^ip[21]^ip[22]^ip[25]^ip[26]^ip[27]^ip[31],
                 datout[92] = ip[0]^ip[1]^ip[3]^ip[6]^ip[7]^ip[8]^ip[9]^ip[11]^ip[15]^ip[16]^ip[18]^ip[20]^ip[21]^ip[24]^ip[25]^ip[26]^ip[30],
                 datout[93] = ip[0]^ip[2]^ip[5]^ip[7]^ip[8]^ip[9]^ip[10]^ip[14]^ip[15]^ip[17]^ip[18]^ip[19]^ip[23]^ip[24]^ip[25]^ip[26]^ip[29]^ip[31],
                 datout[94] = ip[1]^ip[4]^ip[7]^ip[8]^ip[13]^ip[14]^ip[16]^ip[17]^ip[20]^ip[22]^ip[23]^ip[24]^ip[25]^ip[26]^ip[28]^ip[30]^ip[31],
                 datout[95] = ip[0]^ip[3]^ip[6]^ip[7]^ip[12]^ip[13]^ip[15]^ip[16]^ip[19]^ip[21]^ip[22]^ip[23]^ip[24]^ip[25]^ip[27]^ip[29]^ip[30],
                 datout[96] = ip[2]^ip[5]^ip[9]^ip[11]^ip[12]^ip[14]^ip[15]^ip[21]^ip[22]^ip[23]^ip[24]^ip[28]^ip[29]^ip[31],
                 datout[97] = ip[1]^ip[4]^ip[8]^ip[10]^ip[11]^ip[13]^ip[14]^ip[20]^ip[21]^ip[22]^ip[23]^ip[27]^ip[28]^ip[30],
                 datout[98] = ip[0]^ip[3]^ip[7]^ip[9]^ip[10]^ip[12]^ip[13]^ip[19]^ip[20]^ip[21]^ip[22]^ip[26]^ip[27]^ip[29],
                 datout[99] = ip[2]^ip[8]^ip[11]^ip[12]^ip[19]^ip[21]^ip[25]^ip[28]^ip[31],
                 datout[100] = ip[1]^ip[7]^ip[10]^ip[11]^ip[18]^ip[20]^ip[24]^ip[27]^ip[30],
                 datout[101] = ip[0]^ip[6]^ip[9]^ip[10]^ip[17]^ip[19]^ip[23]^ip[26]^ip[29],
                 datout[102] = ip[5]^ip[6]^ip[8]^ip[16]^ip[20]^ip[22]^ip[25]^ip[26]^ip[28]^ip[31],
                 datout[103] = ip[4]^ip[5]^ip[7]^ip[15]^ip[19]^ip[21]^ip[24]^ip[25]^ip[27]^ip[30],
                 datout[104] = ip[3]^ip[4]^ip[6]^ip[14]^ip[18]^ip[20]^ip[23]^ip[24]^ip[26]^ip[29],
                 datout[105] = ip[2]^ip[3]^ip[5]^ip[13]^ip[17]^ip[19]^ip[22]^ip[23]^ip[25]^ip[28],
                 datout[106] = ip[1]^ip[2]^ip[4]^ip[12]^ip[16]^ip[18]^ip[21]^ip[22]^ip[24]^ip[27],
                 datout[107] = ip[0]^ip[1]^ip[3]^ip[11]^ip[15]^ip[17]^ip[20]^ip[21]^ip[23]^ip[26],
                 datout[108] = ip[0]^ip[2]^ip[6]^ip[9]^ip[10]^ip[14]^ip[16]^ip[18]^ip[19]^ip[22]^ip[25]^ip[26]^ip[31],
                 datout[109] = ip[1]^ip[5]^ip[6]^ip[8]^ip[13]^ip[15]^ip[17]^ip[20]^ip[21]^ip[24]^ip[25]^ip[26]^ip[30]^ip[31],
                 datout[110] = ip[0]^ip[4]^ip[5]^ip[7]^ip[12]^ip[14]^ip[16]^ip[19]^ip[20]^ip[23]^ip[24]^ip[25]^ip[29]^ip[30],
                 datout[111] = ip[3]^ip[4]^ip[9]^ip[11]^ip[13]^ip[15]^ip[19]^ip[20]^ip[22]^ip[23]^ip[24]^ip[26]^ip[28]^ip[29]^ip[31],
                 datout[112] = ip[2]^ip[3]^ip[8]^ip[10]^ip[12]^ip[14]^ip[18]^ip[19]^ip[21]^ip[22]^ip[23]^ip[25]^ip[27]^ip[28]^ip[30],
                 datout[113] = ip[1]^ip[2]^ip[7]^ip[9]^ip[11]^ip[13]^ip[17]^ip[18]^ip[20]^ip[21]^ip[22]^ip[24]^ip[26]^ip[27]^ip[29],
                 datout[114] = ip[0]^ip[1]^ip[6]^ip[8]^ip[10]^ip[12]^ip[16]^ip[17]^ip[19]^ip[20]^ip[21]^ip[23]^ip[25]^ip[26]^ip[28],
                 datout[115] = ip[0]^ip[5]^ip[6]^ip[7]^ip[11]^ip[15]^ip[16]^ip[19]^ip[22]^ip[24]^ip[25]^ip[26]^ip[27]^ip[31],
                 datout[116] = ip[4]^ip[5]^ip[9]^ip[10]^ip[14]^ip[15]^ip[20]^ip[21]^ip[23]^ip[24]^ip[25]^ip[30]^ip[31],
                 datout[117] = ip[3]^ip[4]^ip[8]^ip[9]^ip[13]^ip[14]^ip[19]^ip[20]^ip[22]^ip[23]^ip[24]^ip[29]^ip[30],
                 datout[118] = ip[2]^ip[3]^ip[7]^ip[8]^ip[12]^ip[13]^ip[18]^ip[19]^ip[21]^ip[22]^ip[23]^ip[28]^ip[29],
                 datout[119] = ip[1]^ip[2]^ip[6]^ip[7]^ip[11]^ip[12]^ip[17]^ip[18]^ip[20]^ip[21]^ip[22]^ip[27]^ip[28],
                 datout[120] = ip[0]^ip[1]^ip[5]^ip[6]^ip[10]^ip[11]^ip[16]^ip[17]^ip[19]^ip[20]^ip[21]^ip[26]^ip[27],
                 datout[121] = ip[0]^ip[4]^ip[5]^ip[6]^ip[10]^ip[15]^ip[16]^ip[19]^ip[25]^ip[31],
                 datout[122] = ip[3]^ip[4]^ip[5]^ip[6]^ip[14]^ip[15]^ip[20]^ip[24]^ip[26]^ip[30]^ip[31],
                 datout[123] = ip[2]^ip[3]^ip[4]^ip[5]^ip[13]^ip[14]^ip[19]^ip[23]^ip[25]^ip[29]^ip[30],
                 datout[124] = ip[1]^ip[2]^ip[3]^ip[4]^ip[12]^ip[13]^ip[18]^ip[22]^ip[24]^ip[28]^ip[29],
                 datout[125] = ip[0]^ip[1]^ip[2]^ip[3]^ip[11]^ip[12]^ip[17]^ip[21]^ip[23]^ip[27]^ip[28],
                 datout[126] = ip[0]^ip[1]^ip[2]^ip[6]^ip[9]^ip[10]^ip[11]^ip[16]^ip[18]^ip[22]^ip[27]^ip[31],
                 datout[127] = ip[0]^ip[1]^ip[5]^ip[6]^ip[8]^ip[10]^ip[15]^ip[17]^ip[18]^ip[20]^ip[21]^ip[30]^ip[31],
                 datout[128] = ip[0]^ip[4]^ip[5]^ip[6]^ip[7]^ip[14]^ip[16]^ip[17]^ip[18]^ip[19]^ip[26]^ip[29]^ip[30]^ip[31],
                 datout[129] = ip[3]^ip[4]^ip[5]^ip[9]^ip[13]^ip[15]^ip[16]^ip[17]^ip[20]^ip[25]^ip[26]^ip[28]^ip[29]^ip[30]^ip[31],
                 datout[130] = ip[2]^ip[3]^ip[4]^ip[8]^ip[12]^ip[14]^ip[15]^ip[16]^ip[19]^ip[24]^ip[25]^ip[27]^ip[28]^ip[29]^ip[30],
                 datout[131] = ip[1]^ip[2]^ip[3]^ip[7]^ip[11]^ip[13]^ip[14]^ip[15]^ip[18]^ip[23]^ip[24]^ip[26]^ip[27]^ip[28]^ip[29],
                 datout[132] = ip[0]^ip[1]^ip[2]^ip[6]^ip[10]^ip[12]^ip[13]^ip[14]^ip[17]^ip[22]^ip[23]^ip[25]^ip[26]^ip[27]^ip[28],
                 datout[133] = ip[0]^ip[1]^ip[5]^ip[6]^ip[11]^ip[12]^ip[13]^ip[16]^ip[18]^ip[20]^ip[21]^ip[22]^ip[24]^ip[25]^ip[27]^ip[31],
                 datout[134] = ip[0]^ip[4]^ip[5]^ip[6]^ip[9]^ip[10]^ip[11]^ip[12]^ip[15]^ip[17]^ip[18]^ip[19]^ip[21]^ip[23]^ip[24]^ip[30]^ip[31],
                 datout[135] = ip[3]^ip[4]^ip[5]^ip[6]^ip[8]^ip[10]^ip[11]^ip[14]^ip[16]^ip[17]^ip[22]^ip[23]^ip[26]^ip[29]^ip[30]^ip[31],
                 datout[136] = ip[2]^ip[3]^ip[4]^ip[5]^ip[7]^ip[9]^ip[10]^ip[13]^ip[15]^ip[16]^ip[21]^ip[22]^ip[25]^ip[28]^ip[29]^ip[30],
                 datout[137] = ip[1]^ip[2]^ip[3]^ip[4]^ip[6]^ip[8]^ip[9]^ip[12]^ip[14]^ip[15]^ip[20]^ip[21]^ip[24]^ip[27]^ip[28]^ip[29],
                 datout[138] = ip[0]^ip[1]^ip[2]^ip[3]^ip[5]^ip[7]^ip[8]^ip[11]^ip[13]^ip[14]^ip[19]^ip[20]^ip[23]^ip[26]^ip[27]^ip[28],
                 datout[139] = ip[0]^ip[1]^ip[2]^ip[4]^ip[7]^ip[9]^ip[10]^ip[12]^ip[13]^ip[19]^ip[20]^ip[22]^ip[25]^ip[27]^ip[31],
                 datout[140] = ip[0]^ip[1]^ip[3]^ip[8]^ip[11]^ip[12]^ip[19]^ip[20]^ip[21]^ip[24]^ip[30]^ip[31],
                 datout[141] = ip[0]^ip[2]^ip[6]^ip[7]^ip[9]^ip[10]^ip[11]^ip[19]^ip[23]^ip[26]^ip[29]^ip[30]^ip[31],
                 datout[142] = ip[1]^ip[5]^ip[8]^ip[10]^ip[20]^ip[22]^ip[25]^ip[26]^ip[28]^ip[29]^ip[30]^ip[31],
                 datout[143] = ip[0]^ip[4]^ip[7]^ip[9]^ip[19]^ip[21]^ip[24]^ip[25]^ip[27]^ip[28]^ip[29]^ip[30],
                 datout[144] = ip[3]^ip[8]^ip[9]^ip[23]^ip[24]^ip[27]^ip[28]^ip[29]^ip[31],
                 datout[145] = ip[2]^ip[7]^ip[8]^ip[22]^ip[23]^ip[26]^ip[27]^ip[28]^ip[30],
                 datout[146] = ip[1]^ip[6]^ip[7]^ip[21]^ip[22]^ip[25]^ip[26]^ip[27]^ip[29],
                 datout[147] = ip[0]^ip[5]^ip[6]^ip[20]^ip[21]^ip[24]^ip[25]^ip[26]^ip[28],
                 datout[148] = ip[4]^ip[5]^ip[6]^ip[9]^ip[18]^ip[19]^ip[23]^ip[24]^ip[25]^ip[26]^ip[27]^ip[31],
                 datout[149] = ip[3]^ip[4]^ip[5]^ip[8]^ip[17]^ip[18]^ip[22]^ip[23]^ip[24]^ip[25]^ip[26]^ip[30],
                 datout[150] = ip[2]^ip[3]^ip[4]^ip[7]^ip[16]^ip[17]^ip[21]^ip[22]^ip[23]^ip[24]^ip[25]^ip[29],
                 datout[151] = ip[1]^ip[2]^ip[3]^ip[6]^ip[15]^ip[16]^ip[20]^ip[21]^ip[22]^ip[23]^ip[24]^ip[28],
                 datout[152] = ip[0]^ip[1]^ip[2]^ip[5]^ip[14]^ip[15]^ip[19]^ip[20]^ip[21]^ip[22]^ip[23]^ip[27],
                 datout[153] = ip[0]^ip[1]^ip[4]^ip[6]^ip[9]^ip[13]^ip[14]^ip[19]^ip[21]^ip[22]^ip[31],
                 datout[154] = ip[0]^ip[3]^ip[5]^ip[6]^ip[8]^ip[9]^ip[12]^ip[13]^ip[21]^ip[26]^ip[30]^ip[31],
                 datout[155] = ip[2]^ip[4]^ip[5]^ip[6]^ip[7]^ip[8]^ip[9]^ip[11]^ip[12]^ip[18]^ip[25]^ip[26]^ip[29]^ip[30]^ip[31],
                 datout[156] = ip[1]^ip[3]^ip[4]^ip[5]^ip[6]^ip[7]^ip[8]^ip[10]^ip[11]^ip[17]^ip[24]^ip[25]^ip[28]^ip[29]^ip[30],
                 datout[157] = ip[0]^ip[2]^ip[3]^ip[4]^ip[5]^ip[6]^ip[7]^ip[9]^ip[10]^ip[16]^ip[23]^ip[24]^ip[27]^ip[28]^ip[29],
                 datout[158] = ip[1]^ip[2]^ip[3]^ip[4]^ip[5]^ip[8]^ip[15]^ip[18]^ip[20]^ip[22]^ip[23]^ip[27]^ip[28]^ip[31],
                 datout[159] = ip[0]^ip[1]^ip[2]^ip[3]^ip[4]^ip[7]^ip[14]^ip[17]^ip[19]^ip[21]^ip[22]^ip[26]^ip[27]^ip[30],
                 datout[160] = ip[0]^ip[1]^ip[2]^ip[3]^ip[9]^ip[13]^ip[16]^ip[21]^ip[25]^ip[29]^ip[31],
                 datout[161] = ip[0]^ip[1]^ip[2]^ip[6]^ip[8]^ip[9]^ip[12]^ip[15]^ip[18]^ip[24]^ip[26]^ip[28]^ip[30]^ip[31],
                 datout[162] = ip[0]^ip[1]^ip[5]^ip[6]^ip[7]^ip[8]^ip[9]^ip[11]^ip[14]^ip[17]^ip[18]^ip[20]^ip[23]^ip[25]^ip[26]^ip[27]^ip[29]^ip[30]^ip[31],
                 datout[163] = ip[0]^ip[4]^ip[5]^ip[7]^ip[8]^ip[9]^ip[10]^ip[13]^ip[16]^ip[17]^ip[18]^ip[19]^ip[20]^ip[22]^ip[24]^ip[25]^ip[28]^ip[29]^ip[30]^ip[31],
                 datout[164] = ip[3]^ip[4]^ip[7]^ip[8]^ip[12]^ip[15]^ip[16]^ip[17]^ip[19]^ip[20]^ip[21]^ip[23]^ip[24]^ip[26]^ip[27]^ip[28]^ip[29]^ip[30]^ip[31],
                 datout[165] = ip[2]^ip[3]^ip[6]^ip[7]^ip[11]^ip[14]^ip[15]^ip[16]^ip[18]^ip[19]^ip[20]^ip[22]^ip[23]^ip[25]^ip[26]^ip[27]^ip[28]^ip[29]^ip[30],
                 datout[166] = ip[1]^ip[2]^ip[5]^ip[6]^ip[10]^ip[13]^ip[14]^ip[15]^ip[17]^ip[18]^ip[19]^ip[21]^ip[22]^ip[24]^ip[25]^ip[26]^ip[27]^ip[28]^ip[29],
                 datout[167] = ip[0]^ip[1]^ip[4]^ip[5]^ip[9]^ip[12]^ip[13]^ip[14]^ip[16]^ip[17]^ip[18]^ip[20]^ip[21]^ip[23]^ip[24]^ip[25]^ip[26]^ip[27]^ip[28],
                 datout[168] = ip[0]^ip[3]^ip[4]^ip[6]^ip[8]^ip[9]^ip[11]^ip[12]^ip[13]^ip[15]^ip[16]^ip[17]^ip[18]^ip[19]^ip[22]^ip[23]^ip[24]^ip[25]^ip[27]^ip[31],
                 datout[169] = ip[2]^ip[3]^ip[5]^ip[6]^ip[7]^ip[8]^ip[9]^ip[10]^ip[11]^ip[12]^ip[14]^ip[15]^ip[16]^ip[17]^ip[20]^ip[21]^ip[22]^ip[23]^ip[24]^ip[30]^ip[31],
                 datout[170] = ip[1]^ip[2]^ip[4]^ip[5]^ip[6]^ip[7]^ip[8]^ip[9]^ip[10]^ip[11]^ip[13]^ip[14]^ip[15]^ip[16]^ip[19]^ip[20]^ip[21]^ip[22]^ip[23]^ip[29]^ip[30],
                 datout[171] = ip[0]^ip[1]^ip[3]^ip[4]^ip[5]^ip[6]^ip[7]^ip[8]^ip[9]^ip[10]^ip[12]^ip[13]^ip[14]^ip[15]^ip[18]^ip[19]^ip[20]^ip[21]^ip[22]^ip[28]^ip[29],
                 datout[172] = ip[0]^ip[2]^ip[3]^ip[4]^ip[5]^ip[7]^ip[8]^ip[11]^ip[12]^ip[13]^ip[14]^ip[17]^ip[19]^ip[21]^ip[26]^ip[27]^ip[28]^ip[31],
                 datout[173] = ip[1]^ip[2]^ip[3]^ip[4]^ip[7]^ip[9]^ip[10]^ip[11]^ip[12]^ip[13]^ip[16]^ip[25]^ip[27]^ip[30]^ip[31],
                 datout[174] = ip[0]^ip[1]^ip[2]^ip[3]^ip[6]^ip[8]^ip[9]^ip[10]^ip[11]^ip[12]^ip[15]^ip[24]^ip[26]^ip[29]^ip[30],
                 datout[175] = ip[0]^ip[1]^ip[2]^ip[5]^ip[6]^ip[7]^ip[8]^ip[10]^ip[11]^ip[14]^ip[18]^ip[20]^ip[23]^ip[25]^ip[26]^ip[28]^ip[29]^ip[31],
                 datout[176] = ip[0]^ip[1]^ip[4]^ip[5]^ip[7]^ip[10]^ip[13]^ip[17]^ip[18]^ip[19]^ip[20]^ip[22]^ip[24]^ip[25]^ip[26]^ip[27]^ip[28]^ip[30]^ip[31],
                 datout[177] = ip[0]^ip[3]^ip[4]^ip[12]^ip[16]^ip[17]^ip[19]^ip[20]^ip[21]^ip[23]^ip[24]^ip[25]^ip[27]^ip[29]^ip[30]^ip[31],
                 datout[178] = ip[2]^ip[3]^ip[6]^ip[9]^ip[11]^ip[15]^ip[16]^ip[19]^ip[22]^ip[23]^ip[24]^ip[28]^ip[29]^ip[30]^ip[31],
                 datout[179] = ip[1]^ip[2]^ip[5]^ip[8]^ip[10]^ip[14]^ip[15]^ip[18]^ip[21]^ip[22]^ip[23]^ip[27]^ip[28]^ip[29]^ip[30],
                 datout[180] = ip[0]^ip[1]^ip[4]^ip[7]^ip[9]^ip[13]^ip[14]^ip[17]^ip[20]^ip[21]^ip[22]^ip[26]^ip[27]^ip[28]^ip[29],
                 datout[181] = ip[0]^ip[3]^ip[8]^ip[9]^ip[12]^ip[13]^ip[16]^ip[18]^ip[19]^ip[21]^ip[25]^ip[27]^ip[28]^ip[31],
                 datout[182] = ip[2]^ip[6]^ip[7]^ip[8]^ip[9]^ip[11]^ip[12]^ip[15]^ip[17]^ip[24]^ip[27]^ip[30]^ip[31],
                 datout[183] = ip[1]^ip[5]^ip[6]^ip[7]^ip[8]^ip[10]^ip[11]^ip[14]^ip[16]^ip[23]^ip[26]^ip[29]^ip[30],
                 datout[184] = ip[0]^ip[4]^ip[5]^ip[6]^ip[7]^ip[9]^ip[10]^ip[13]^ip[15]^ip[22]^ip[25]^ip[28]^ip[29],
                 datout[185] = ip[3]^ip[4]^ip[5]^ip[8]^ip[12]^ip[14]^ip[18]^ip[20]^ip[21]^ip[24]^ip[26]^ip[27]^ip[28]^ip[31],
                 datout[186] = ip[2]^ip[3]^ip[4]^ip[7]^ip[11]^ip[13]^ip[17]^ip[19]^ip[20]^ip[23]^ip[25]^ip[26]^ip[27]^ip[30],
                 datout[187] = ip[1]^ip[2]^ip[3]^ip[6]^ip[10]^ip[12]^ip[16]^ip[18]^ip[19]^ip[22]^ip[24]^ip[25]^ip[26]^ip[29],
                 datout[188] = ip[0]^ip[1]^ip[2]^ip[5]^ip[9]^ip[11]^ip[15]^ip[17]^ip[18]^ip[21]^ip[23]^ip[24]^ip[25]^ip[28],
                 datout[189] = ip[0]^ip[1]^ip[4]^ip[6]^ip[8]^ip[9]^ip[10]^ip[14]^ip[16]^ip[17]^ip[18]^ip[22]^ip[23]^ip[24]^ip[26]^ip[27]^ip[31],
                 datout[190] = ip[0]^ip[3]^ip[5]^ip[6]^ip[7]^ip[8]^ip[13]^ip[15]^ip[16]^ip[17]^ip[18]^ip[20]^ip[21]^ip[22]^ip[23]^ip[25]^ip[30]^ip[31],
                 datout[191] = ip[2]^ip[4]^ip[5]^ip[7]^ip[9]^ip[12]^ip[14]^ip[15]^ip[16]^ip[17]^ip[18]^ip[19]^ip[21]^ip[22]^ip[24]^ip[26]^ip[29]^ip[30]^ip[31],
                 datout[192] = ip[1]^ip[3]^ip[4]^ip[6]^ip[8]^ip[11]^ip[13]^ip[14]^ip[15]^ip[16]^ip[17]^ip[18]^ip[20]^ip[21]^ip[23]^ip[25]^ip[28]^ip[29]^ip[30],
                 datout[193] = ip[0]^ip[2]^ip[3]^ip[5]^ip[7]^ip[10]^ip[12]^ip[13]^ip[14]^ip[15]^ip[16]^ip[17]^ip[19]^ip[20]^ip[22]^ip[24]^ip[27]^ip[28]^ip[29],
                 datout[194] = ip[1]^ip[2]^ip[4]^ip[11]^ip[12]^ip[13]^ip[14]^ip[15]^ip[16]^ip[19]^ip[20]^ip[21]^ip[23]^ip[27]^ip[28]^ip[31],
                 datout[195] = ip[0]^ip[1]^ip[3]^ip[10]^ip[11]^ip[12]^ip[13]^ip[14]^ip[15]^ip[18]^ip[19]^ip[20]^ip[22]^ip[26]^ip[27]^ip[30],
                 datout[196] = ip[0]^ip[2]^ip[6]^ip[10]^ip[11]^ip[12]^ip[13]^ip[14]^ip[17]^ip[19]^ip[20]^ip[21]^ip[25]^ip[29]^ip[31],
                 datout[197] = ip[1]^ip[5]^ip[6]^ip[10]^ip[11]^ip[12]^ip[13]^ip[16]^ip[19]^ip[24]^ip[26]^ip[28]^ip[30]^ip[31],
                 datout[198] = ip[0]^ip[4]^ip[5]^ip[9]^ip[10]^ip[11]^ip[12]^ip[15]^ip[18]^ip[23]^ip[25]^ip[27]^ip[29]^ip[30],
                 datout[199] = ip[3]^ip[4]^ip[6]^ip[8]^ip[10]^ip[11]^ip[14]^ip[17]^ip[18]^ip[20]^ip[22]^ip[24]^ip[28]^ip[29]^ip[31],
                 datout[200] = ip[2]^ip[3]^ip[5]^ip[7]^ip[9]^ip[10]^ip[13]^ip[16]^ip[17]^ip[19]^ip[21]^ip[23]^ip[27]^ip[28]^ip[30],
                 datout[201] = ip[1]^ip[2]^ip[4]^ip[6]^ip[8]^ip[9]^ip[12]^ip[15]^ip[16]^ip[18]^ip[20]^ip[22]^ip[26]^ip[27]^ip[29],
                 datout[202] = ip[0]^ip[1]^ip[3]^ip[5]^ip[7]^ip[8]^ip[11]^ip[14]^ip[15]^ip[17]^ip[19]^ip[21]^ip[25]^ip[26]^ip[28],
                 datout[203] = ip[0]^ip[2]^ip[4]^ip[7]^ip[9]^ip[10]^ip[13]^ip[14]^ip[16]^ip[24]^ip[25]^ip[26]^ip[27]^ip[31],
                 datout[204] = ip[1]^ip[3]^ip[8]^ip[12]^ip[13]^ip[15]^ip[18]^ip[20]^ip[23]^ip[24]^ip[25]^ip[30]^ip[31],
                 datout[205] = ip[0]^ip[2]^ip[7]^ip[11]^ip[12]^ip[14]^ip[17]^ip[19]^ip[22]^ip[23]^ip[24]^ip[29]^ip[30],
                 datout[206] = ip[1]^ip[9]^ip[10]^ip[11]^ip[13]^ip[16]^ip[20]^ip[21]^ip[22]^ip[23]^ip[26]^ip[28]^ip[29]^ip[31],
                 datout[207] = ip[0]^ip[8]^ip[9]^ip[10]^ip[12]^ip[15]^ip[19]^ip[20]^ip[21]^ip[22]^ip[25]^ip[27]^ip[28]^ip[30],
                 datout[208] = ip[6]^ip[7]^ip[8]^ip[11]^ip[14]^ip[19]^ip[21]^ip[24]^ip[27]^ip[29]^ip[31],
                 datout[209] = ip[5]^ip[6]^ip[7]^ip[10]^ip[13]^ip[18]^ip[20]^ip[23]^ip[26]^ip[28]^ip[30],
                 datout[210] = ip[4]^ip[5]^ip[6]^ip[9]^ip[12]^ip[17]^ip[19]^ip[22]^ip[25]^ip[27]^ip[29],
                 datout[211] = ip[3]^ip[4]^ip[5]^ip[8]^ip[11]^ip[16]^ip[18]^ip[21]^ip[24]^ip[26]^ip[28],
                 datout[212] = ip[2]^ip[3]^ip[4]^ip[7]^ip[10]^ip[15]^ip[17]^ip[20]^ip[23]^ip[25]^ip[27],
                 datout[213] = ip[1]^ip[2]^ip[3]^ip[6]^ip[9]^ip[14]^ip[16]^ip[19]^ip[22]^ip[24]^ip[26],
                 datout[214] = ip[0]^ip[1]^ip[2]^ip[5]^ip[8]^ip[13]^ip[15]^ip[18]^ip[21]^ip[23]^ip[25],
                 datout[215] = ip[0]^ip[1]^ip[4]^ip[6]^ip[7]^ip[9]^ip[12]^ip[14]^ip[17]^ip[18]^ip[22]^ip[24]^ip[26]^ip[31],
                 datout[216] = ip[0]^ip[3]^ip[5]^ip[8]^ip[9]^ip[11]^ip[13]^ip[16]^ip[17]^ip[18]^ip[20]^ip[21]^ip[23]^ip[25]^ip[26]^ip[30]^ip[31],
                 datout[217] = ip[2]^ip[4]^ip[6]^ip[7]^ip[8]^ip[9]^ip[10]^ip[12]^ip[15]^ip[16]^ip[17]^ip[18]^ip[19]^ip[22]^ip[24]^ip[25]^ip[26]^ip[29]^ip[30]^ip[31],
                 datout[218] = ip[1]^ip[3]^ip[5]^ip[6]^ip[7]^ip[8]^ip[9]^ip[11]^ip[14]^ip[15]^ip[16]^ip[17]^ip[18]^ip[21]^ip[23]^ip[24]^ip[25]^ip[28]^ip[29]^ip[30],
                 datout[219] = ip[0]^ip[2]^ip[4]^ip[5]^ip[6]^ip[7]^ip[8]^ip[10]^ip[13]^ip[14]^ip[15]^ip[16]^ip[17]^ip[20]^ip[22]^ip[23]^ip[24]^ip[27]^ip[28]^ip[29],
                 datout[220] = ip[1]^ip[3]^ip[4]^ip[5]^ip[7]^ip[12]^ip[13]^ip[14]^ip[15]^ip[16]^ip[18]^ip[19]^ip[20]^ip[21]^ip[22]^ip[23]^ip[27]^ip[28]^ip[31],
                 datout[221] = ip[0]^ip[2]^ip[3]^ip[4]^ip[6]^ip[11]^ip[12]^ip[13]^ip[14]^ip[15]^ip[17]^ip[18]^ip[19]^ip[20]^ip[21]^ip[22]^ip[26]^ip[27]^ip[30],
                 datout[222] = ip[1]^ip[2]^ip[3]^ip[5]^ip[6]^ip[9]^ip[10]^ip[11]^ip[12]^ip[13]^ip[14]^ip[16]^ip[17]^ip[19]^ip[21]^ip[25]^ip[29]^ip[31],
                 datout[223] = ip[0]^ip[1]^ip[2]^ip[4]^ip[5]^ip[8]^ip[9]^ip[10]^ip[11]^ip[12]^ip[13]^ip[15]^ip[16]^ip[18]^ip[20]^ip[24]^ip[28]^ip[30],
                 datout[224] = ip[0]^ip[1]^ip[3]^ip[4]^ip[6]^ip[7]^ip[8]^ip[10]^ip[11]^ip[12]^ip[14]^ip[15]^ip[17]^ip[18]^ip[19]^ip[20]^ip[23]^ip[26]^ip[27]^ip[29]^ip[31],
                 datout[225] = ip[0]^ip[2]^ip[3]^ip[5]^ip[7]^ip[10]^ip[11]^ip[13]^ip[14]^ip[16]^ip[17]^ip[19]^ip[20]^ip[22]^ip[25]^ip[28]^ip[30]^ip[31],
                 datout[226] = ip[1]^ip[2]^ip[4]^ip[10]^ip[12]^ip[13]^ip[15]^ip[16]^ip[19]^ip[20]^ip[21]^ip[24]^ip[26]^ip[27]^ip[29]^ip[30]^ip[31],
                 datout[227] = ip[0]^ip[1]^ip[3]^ip[9]^ip[11]^ip[12]^ip[14]^ip[15]^ip[18]^ip[19]^ip[20]^ip[23]^ip[25]^ip[26]^ip[28]^ip[29]^ip[30],
                 datout[228] = ip[0]^ip[2]^ip[6]^ip[8]^ip[9]^ip[10]^ip[11]^ip[13]^ip[14]^ip[17]^ip[19]^ip[20]^ip[22]^ip[24]^ip[25]^ip[26]^ip[27]^ip[28]^ip[29]^ip[31],
                 datout[229] = ip[1]^ip[5]^ip[6]^ip[7]^ip[8]^ip[10]^ip[12]^ip[13]^ip[16]^ip[19]^ip[20]^ip[21]^ip[23]^ip[24]^ip[25]^ip[27]^ip[28]^ip[30]^ip[31],
                 datout[230] = ip[0]^ip[4]^ip[5]^ip[6]^ip[7]^ip[9]^ip[11]^ip[12]^ip[15]^ip[18]^ip[19]^ip[20]^ip[22]^ip[23]^ip[24]^ip[26]^ip[27]^ip[29]^ip[30],
                 datout[231] = ip[3]^ip[4]^ip[5]^ip[8]^ip[9]^ip[10]^ip[11]^ip[14]^ip[17]^ip[19]^ip[20]^ip[21]^ip[22]^ip[23]^ip[25]^ip[28]^ip[29]^ip[31],
                 datout[232] = ip[2]^ip[3]^ip[4]^ip[7]^ip[8]^ip[9]^ip[10]^ip[13]^ip[16]^ip[18]^ip[19]^ip[20]^ip[21]^ip[22]^ip[24]^ip[27]^ip[28]^ip[30],
                 datout[233] = ip[1]^ip[2]^ip[3]^ip[6]^ip[7]^ip[8]^ip[9]^ip[12]^ip[15]^ip[17]^ip[18]^ip[19]^ip[20]^ip[21]^ip[23]^ip[26]^ip[27]^ip[29],
                 datout[234] = ip[0]^ip[1]^ip[2]^ip[5]^ip[6]^ip[7]^ip[8]^ip[11]^ip[14]^ip[16]^ip[17]^ip[18]^ip[19]^ip[20]^ip[22]^ip[25]^ip[26]^ip[28],
                 datout[235] = ip[0]^ip[1]^ip[4]^ip[5]^ip[7]^ip[9]^ip[10]^ip[13]^ip[15]^ip[16]^ip[17]^ip[19]^ip[20]^ip[21]^ip[24]^ip[25]^ip[26]^ip[27]^ip[31],
                 datout[236] = ip[0]^ip[3]^ip[4]^ip[8]^ip[12]^ip[14]^ip[15]^ip[16]^ip[19]^ip[23]^ip[24]^ip[25]^ip[30]^ip[31],
                 datout[237] = ip[2]^ip[3]^ip[6]^ip[7]^ip[9]^ip[11]^ip[13]^ip[14]^ip[15]^ip[20]^ip[22]^ip[23]^ip[24]^ip[26]^ip[29]^ip[30]^ip[31],
                 datout[238] = ip[1]^ip[2]^ip[5]^ip[6]^ip[8]^ip[10]^ip[12]^ip[13]^ip[14]^ip[19]^ip[21]^ip[22]^ip[23]^ip[25]^ip[28]^ip[29]^ip[30],
                 datout[239] = ip[0]^ip[1]^ip[4]^ip[5]^ip[7]^ip[9]^ip[11]^ip[12]^ip[13]^ip[18]^ip[20]^ip[21]^ip[22]^ip[24]^ip[27]^ip[28]^ip[29],
                 datout[240] = ip[0]^ip[3]^ip[4]^ip[8]^ip[9]^ip[10]^ip[11]^ip[12]^ip[17]^ip[18]^ip[19]^ip[21]^ip[23]^ip[27]^ip[28]^ip[31],
                 datout[241] = ip[2]^ip[3]^ip[6]^ip[7]^ip[8]^ip[10]^ip[11]^ip[16]^ip[17]^ip[22]^ip[27]^ip[30]^ip[31],
                 datout[242] = ip[1]^ip[2]^ip[5]^ip[6]^ip[7]^ip[9]^ip[10]^ip[15]^ip[16]^ip[21]^ip[26]^ip[29]^ip[30],
                 datout[243] = ip[0]^ip[1]^ip[4]^ip[5]^ip[6]^ip[8]^ip[9]^ip[14]^ip[15]^ip[20]^ip[25]^ip[28]^ip[29],
                 datout[244] = ip[0]^ip[3]^ip[4]^ip[5]^ip[6]^ip[7]^ip[8]^ip[9]^ip[13]^ip[14]^ip[18]^ip[19]^ip[20]^ip[24]^ip[26]^ip[27]^ip[28]^ip[31],
                 datout[245] = ip[2]^ip[3]^ip[4]^ip[5]^ip[7]^ip[8]^ip[9]^ip[12]^ip[13]^ip[17]^ip[19]^ip[20]^ip[23]^ip[25]^ip[27]^ip[30]^ip[31],
                 datout[246] = ip[1]^ip[2]^ip[3]^ip[4]^ip[6]^ip[7]^ip[8]^ip[11]^ip[12]^ip[16]^ip[18]^ip[19]^ip[22]^ip[24]^ip[26]^ip[29]^ip[30],
                 datout[247] = ip[0]^ip[1]^ip[2]^ip[3]^ip[5]^ip[6]^ip[7]^ip[10]^ip[11]^ip[15]^ip[17]^ip[18]^ip[21]^ip[23]^ip[25]^ip[28]^ip[29],
                 datout[248] = ip[0]^ip[1]^ip[2]^ip[4]^ip[5]^ip[10]^ip[14]^ip[16]^ip[17]^ip[18]^ip[22]^ip[24]^ip[26]^ip[27]^ip[28]^ip[31],
                 datout[249] = ip[0]^ip[1]^ip[3]^ip[4]^ip[6]^ip[13]^ip[15]^ip[16]^ip[17]^ip[18]^ip[20]^ip[21]^ip[23]^ip[25]^ip[27]^ip[30]^ip[31],
                 datout[250] = ip[0]^ip[2]^ip[3]^ip[5]^ip[6]^ip[9]^ip[12]^ip[14]^ip[15]^ip[16]^ip[17]^ip[18]^ip[19]^ip[22]^ip[24]^ip[29]^ip[30]^ip[31],
                 datout[251] = ip[1]^ip[2]^ip[4]^ip[5]^ip[6]^ip[8]^ip[9]^ip[11]^ip[13]^ip[14]^ip[15]^ip[16]^ip[17]^ip[20]^ip[21]^ip[23]^ip[26]^ip[28]^ip[29]^ip[30]^ip[31],
                 datout[252] = ip[0]^ip[1]^ip[3]^ip[4]^ip[5]^ip[7]^ip[8]^ip[10]^ip[12]^ip[13]^ip[14]^ip[15]^ip[16]^ip[19]^ip[20]^ip[22]^ip[25]^ip[27]^ip[28]^ip[29]^ip[30],
                 datout[253] = ip[0]^ip[2]^ip[3]^ip[4]^ip[7]^ip[11]^ip[12]^ip[13]^ip[14]^ip[15]^ip[19]^ip[20]^ip[21]^ip[24]^ip[27]^ip[28]^ip[29]^ip[31],
                 datout[254] = ip[1]^ip[2]^ip[3]^ip[9]^ip[10]^ip[11]^ip[12]^ip[13]^ip[14]^ip[19]^ip[23]^ip[27]^ip[28]^ip[30]^ip[31],
                 datout[255] = ip[0]^ip[1]^ip[2]^ip[8]^ip[9]^ip[10]^ip[11]^ip[12]^ip[13]^ip[18]^ip[22]^ip[26]^ip[27]^ip[29]^ip[30],
                 datout[256] = ip[0]^ip[1]^ip[6]^ip[7]^ip[8]^ip[10]^ip[11]^ip[12]^ip[17]^ip[18]^ip[20]^ip[21]^ip[25]^ip[28]^ip[29]^ip[31],
                 datout[257] = ip[0]^ip[5]^ip[7]^ip[10]^ip[11]^ip[16]^ip[17]^ip[18]^ip[19]^ip[24]^ip[26]^ip[27]^ip[28]^ip[30]^ip[31],
                 datout[258] = ip[4]^ip[10]^ip[15]^ip[16]^ip[17]^ip[20]^ip[23]^ip[25]^ip[27]^ip[29]^ip[30]^ip[31],
                 datout[259] = ip[3]^ip[9]^ip[14]^ip[15]^ip[16]^ip[19]^ip[22]^ip[24]^ip[26]^ip[28]^ip[29]^ip[30],
                 datout[260] = ip[2]^ip[8]^ip[13]^ip[14]^ip[15]^ip[18]^ip[21]^ip[23]^ip[25]^ip[27]^ip[28]^ip[29],
                 datout[261] = ip[1]^ip[7]^ip[12]^ip[13]^ip[14]^ip[17]^ip[20]^ip[22]^ip[24]^ip[26]^ip[27]^ip[28],
                 datout[262] = ip[0]^ip[6]^ip[11]^ip[12]^ip[13]^ip[16]^ip[19]^ip[21]^ip[23]^ip[25]^ip[26]^ip[27],
                 datout[263] = ip[5]^ip[6]^ip[9]^ip[10]^ip[11]^ip[12]^ip[15]^ip[22]^ip[24]^ip[25]^ip[31],
                 datout[264] = ip[4]^ip[5]^ip[8]^ip[9]^ip[10]^ip[11]^ip[14]^ip[21]^ip[23]^ip[24]^ip[30],
                 datout[265] = ip[3]^ip[4]^ip[7]^ip[8]^ip[9]^ip[10]^ip[13]^ip[20]^ip[22]^ip[23]^ip[29],
                 datout[266] = ip[2]^ip[3]^ip[6]^ip[7]^ip[8]^ip[9]^ip[12]^ip[19]^ip[21]^ip[22]^ip[28],
                 datout[267] = ip[1]^ip[2]^ip[5]^ip[6]^ip[7]^ip[8]^ip[11]^ip[18]^ip[20]^ip[21]^ip[27],
                 datout[268] = ip[0]^ip[1]^ip[4]^ip[5]^ip[6]^ip[7]^ip[10]^ip[17]^ip[19]^ip[20]^ip[26],
                 datout[269] = ip[0]^ip[3]^ip[4]^ip[5]^ip[16]^ip[19]^ip[20]^ip[25]^ip[26]^ip[31],
                 datout[270] = ip[2]^ip[3]^ip[4]^ip[6]^ip[9]^ip[15]^ip[19]^ip[20]^ip[24]^ip[25]^ip[26]^ip[30]^ip[31],
                 datout[271] = ip[1]^ip[2]^ip[3]^ip[5]^ip[8]^ip[14]^ip[18]^ip[19]^ip[23]^ip[24]^ip[25]^ip[29]^ip[30],
                 datout[272] = ip[0]^ip[1]^ip[2]^ip[4]^ip[7]^ip[13]^ip[17]^ip[18]^ip[22]^ip[23]^ip[24]^ip[28]^ip[29],
                 datout[273] = ip[0]^ip[1]^ip[3]^ip[9]^ip[12]^ip[16]^ip[17]^ip[18]^ip[20]^ip[21]^ip[22]^ip[23]^ip[26]^ip[27]^ip[28]^ip[31],
                 datout[274] = ip[0]^ip[2]^ip[6]^ip[8]^ip[9]^ip[11]^ip[15]^ip[16]^ip[17]^ip[18]^ip[19]^ip[21]^ip[22]^ip[25]^ip[27]^ip[30]^ip[31],
                 datout[275] = ip[1]^ip[5]^ip[6]^ip[7]^ip[8]^ip[9]^ip[10]^ip[14]^ip[15]^ip[16]^ip[17]^ip[21]^ip[24]^ip[29]^ip[30]^ip[31],
                 datout[276] = ip[0]^ip[4]^ip[5]^ip[6]^ip[7]^ip[8]^ip[9]^ip[13]^ip[14]^ip[15]^ip[16]^ip[20]^ip[23]^ip[28]^ip[29]^ip[30],
                 datout[277] = ip[3]^ip[4]^ip[5]^ip[7]^ip[8]^ip[9]^ip[12]^ip[13]^ip[14]^ip[15]^ip[18]^ip[19]^ip[20]^ip[22]^ip[26]^ip[27]^ip[28]^ip[29]^ip[31],
                 datout[278] = ip[2]^ip[3]^ip[4]^ip[6]^ip[7]^ip[8]^ip[11]^ip[12]^ip[13]^ip[14]^ip[17]^ip[18]^ip[19]^ip[21]^ip[25]^ip[26]^ip[27]^ip[28]^ip[30],
                 datout[279] = ip[1]^ip[2]^ip[3]^ip[5]^ip[6]^ip[7]^ip[10]^ip[11]^ip[12]^ip[13]^ip[16]^ip[17]^ip[18]^ip[20]^ip[24]^ip[25]^ip[26]^ip[27]^ip[29],
                 datout[280] = ip[0]^ip[1]^ip[2]^ip[4]^ip[5]^ip[6]^ip[9]^ip[10]^ip[11]^ip[12]^ip[15]^ip[16]^ip[17]^ip[19]^ip[23]^ip[24]^ip[25]^ip[26]^ip[28],
                 datout[281] = ip[0]^ip[1]^ip[3]^ip[4]^ip[5]^ip[6]^ip[8]^ip[10]^ip[11]^ip[14]^ip[15]^ip[16]^ip[20]^ip[22]^ip[23]^ip[24]^ip[25]^ip[26]^ip[27]^ip[31],
                 datout[282] = ip[0]^ip[2]^ip[3]^ip[4]^ip[5]^ip[6]^ip[7]^ip[10]^ip[13]^ip[14]^ip[15]^ip[18]^ip[19]^ip[20]^ip[21]^ip[22]^ip[23]^ip[24]^ip[25]^ip[30]^ip[31],
                 datout[283] = ip[1]^ip[2]^ip[3]^ip[4]^ip[5]^ip[12]^ip[13]^ip[14]^ip[17]^ip[19]^ip[21]^ip[22]^ip[23]^ip[24]^ip[26]^ip[29]^ip[30]^ip[31],
                 datout[284] = ip[0]^ip[1]^ip[2]^ip[3]^ip[4]^ip[11]^ip[12]^ip[13]^ip[16]^ip[18]^ip[20]^ip[21]^ip[22]^ip[23]^ip[25]^ip[28]^ip[29]^ip[30],
                 datout[285] = ip[0]^ip[1]^ip[2]^ip[3]^ip[6]^ip[9]^ip[10]^ip[11]^ip[12]^ip[15]^ip[17]^ip[18]^ip[19]^ip[21]^ip[22]^ip[24]^ip[26]^ip[27]^ip[28]^ip[29]^ip[31],
                 datout[286] = ip[0]^ip[1]^ip[2]^ip[5]^ip[6]^ip[8]^ip[10]^ip[11]^ip[14]^ip[16]^ip[17]^ip[21]^ip[23]^ip[25]^ip[27]^ip[28]^ip[30]^ip[31],
                 datout[287] = ip[0]^ip[1]^ip[4]^ip[5]^ip[6]^ip[7]^ip[10]^ip[13]^ip[15]^ip[16]^ip[18]^ip[22]^ip[24]^ip[27]^ip[29]^ip[30]^ip[31],
                 datout[288] = ip[0]^ip[3]^ip[4]^ip[5]^ip[12]^ip[14]^ip[15]^ip[17]^ip[18]^ip[20]^ip[21]^ip[23]^ip[28]^ip[29]^ip[30]^ip[31],
                 datout[289] = ip[2]^ip[3]^ip[4]^ip[6]^ip[9]^ip[11]^ip[13]^ip[14]^ip[16]^ip[17]^ip[18]^ip[19]^ip[22]^ip[26]^ip[27]^ip[28]^ip[29]^ip[30]^ip[31],
                 datout[290] = ip[1]^ip[2]^ip[3]^ip[5]^ip[8]^ip[10]^ip[12]^ip[13]^ip[15]^ip[16]^ip[17]^ip[18]^ip[21]^ip[25]^ip[26]^ip[27]^ip[28]^ip[29]^ip[30],
                 datout[291] = ip[0]^ip[1]^ip[2]^ip[4]^ip[7]^ip[9]^ip[11]^ip[12]^ip[14]^ip[15]^ip[16]^ip[17]^ip[20]^ip[24]^ip[25]^ip[26]^ip[27]^ip[28]^ip[29],
                 datout[292] = ip[0]^ip[1]^ip[3]^ip[8]^ip[9]^ip[10]^ip[11]^ip[13]^ip[14]^ip[15]^ip[16]^ip[18]^ip[19]^ip[20]^ip[23]^ip[24]^ip[25]^ip[27]^ip[28]^ip[31],
                 datout[293] = ip[0]^ip[2]^ip[6]^ip[7]^ip[8]^ip[10]^ip[12]^ip[13]^ip[14]^ip[15]^ip[17]^ip[19]^ip[20]^ip[22]^ip[23]^ip[24]^ip[27]^ip[30]^ip[31],
                 datout[294] = ip[1]^ip[5]^ip[7]^ip[11]^ip[12]^ip[13]^ip[14]^ip[16]^ip[19]^ip[20]^ip[21]^ip[22]^ip[23]^ip[29]^ip[30]^ip[31],
                 datout[295] = ip[0]^ip[4]^ip[6]^ip[10]^ip[11]^ip[12]^ip[13]^ip[15]^ip[18]^ip[19]^ip[20]^ip[21]^ip[22]^ip[28]^ip[29]^ip[30],
                 datout[296] = ip[3]^ip[5]^ip[6]^ip[10]^ip[11]^ip[12]^ip[14]^ip[17]^ip[19]^ip[21]^ip[26]^ip[27]^ip[28]^ip[29]^ip[31],
                 datout[297] = ip[2]^ip[4]^ip[5]^ip[9]^ip[10]^ip[11]^ip[13]^ip[16]^ip[18]^ip[20]^ip[25]^ip[26]^ip[27]^ip[28]^ip[30],
                 datout[298] = ip[1]^ip[3]^ip[4]^ip[8]^ip[9]^ip[10]^ip[12]^ip[15]^ip[17]^ip[19]^ip[24]^ip[25]^ip[26]^ip[27]^ip[29],
                 datout[299] = ip[0]^ip[2]^ip[3]^ip[7]^ip[8]^ip[9]^ip[11]^ip[14]^ip[16]^ip[18]^ip[23]^ip[24]^ip[25]^ip[26]^ip[28],
                 datout[300] = ip[1]^ip[2]^ip[7]^ip[8]^ip[9]^ip[10]^ip[13]^ip[15]^ip[17]^ip[18]^ip[20]^ip[22]^ip[23]^ip[24]^ip[25]^ip[26]^ip[27]^ip[31],
                 datout[301] = ip[0]^ip[1]^ip[6]^ip[7]^ip[8]^ip[9]^ip[12]^ip[14]^ip[16]^ip[17]^ip[19]^ip[21]^ip[22]^ip[23]^ip[24]^ip[25]^ip[26]^ip[30],
                 datout[302] = ip[0]^ip[5]^ip[7]^ip[8]^ip[9]^ip[11]^ip[13]^ip[15]^ip[16]^ip[21]^ip[22]^ip[23]^ip[24]^ip[25]^ip[26]^ip[29]^ip[31],
                 datout[303] = ip[4]^ip[7]^ip[8]^ip[9]^ip[10]^ip[12]^ip[14]^ip[15]^ip[18]^ip[21]^ip[22]^ip[23]^ip[24]^ip[25]^ip[26]^ip[28]^ip[30]^ip[31],
                 datout[304] = ip[3]^ip[6]^ip[7]^ip[8]^ip[9]^ip[11]^ip[13]^ip[14]^ip[17]^ip[20]^ip[21]^ip[22]^ip[23]^ip[24]^ip[25]^ip[27]^ip[29]^ip[30],
                 datout[305] = ip[2]^ip[5]^ip[6]^ip[7]^ip[8]^ip[10]^ip[12]^ip[13]^ip[16]^ip[19]^ip[20]^ip[21]^ip[22]^ip[23]^ip[24]^ip[26]^ip[28]^ip[29],
                 datout[306] = ip[1]^ip[4]^ip[5]^ip[6]^ip[7]^ip[9]^ip[11]^ip[12]^ip[15]^ip[18]^ip[19]^ip[20]^ip[21]^ip[22]^ip[23]^ip[25]^ip[27]^ip[28],
                 datout[307] = ip[0]^ip[3]^ip[4]^ip[5]^ip[6]^ip[8]^ip[10]^ip[11]^ip[14]^ip[17]^ip[18]^ip[19]^ip[20]^ip[21]^ip[22]^ip[24]^ip[26]^ip[27],
                 datout[308] = ip[2]^ip[3]^ip[4]^ip[5]^ip[6]^ip[7]^ip[10]^ip[13]^ip[16]^ip[17]^ip[19]^ip[21]^ip[23]^ip[25]^ip[31],
                 datout[309] = ip[1]^ip[2]^ip[3]^ip[4]^ip[5]^ip[6]^ip[9]^ip[12]^ip[15]^ip[16]^ip[18]^ip[20]^ip[22]^ip[24]^ip[30],
                 datout[310] = ip[0]^ip[1]^ip[2]^ip[3]^ip[4]^ip[5]^ip[8]^ip[11]^ip[14]^ip[15]^ip[17]^ip[19]^ip[21]^ip[23]^ip[29],
                 datout[311] = ip[0]^ip[1]^ip[2]^ip[3]^ip[4]^ip[6]^ip[7]^ip[9]^ip[10]^ip[13]^ip[14]^ip[16]^ip[22]^ip[26]^ip[28]^ip[31],
                 datout[312] = ip[0]^ip[1]^ip[2]^ip[3]^ip[5]^ip[8]^ip[12]^ip[13]^ip[15]^ip[18]^ip[20]^ip[21]^ip[25]^ip[26]^ip[27]^ip[30]^ip[31],
                 datout[313] = ip[0]^ip[1]^ip[2]^ip[4]^ip[6]^ip[7]^ip[9]^ip[11]^ip[12]^ip[14]^ip[17]^ip[18]^ip[19]^ip[24]^ip[25]^ip[29]^ip[30]^ip[31],
                 datout[314] = ip[0]^ip[1]^ip[3]^ip[5]^ip[8]^ip[9]^ip[10]^ip[11]^ip[13]^ip[16]^ip[17]^ip[20]^ip[23]^ip[24]^ip[26]^ip[28]^ip[29]^ip[30]^ip[31],
                 datout[315] = ip[0]^ip[2]^ip[4]^ip[6]^ip[7]^ip[8]^ip[10]^ip[12]^ip[15]^ip[16]^ip[18]^ip[19]^ip[20]^ip[22]^ip[23]^ip[25]^ip[26]^ip[27]^ip[28]^ip[29]^ip[30]^
                         ip[31],
                 datout[316] = ip[1]^ip[3]^ip[5]^ip[7]^ip[11]^ip[14]^ip[15]^ip[17]^ip[19]^ip[20]^ip[21]^ip[22]^ip[24]^ip[25]^ip[27]^ip[28]^ip[29]^ip[30]^ip[31],
                 datout[317] = ip[0]^ip[2]^ip[4]^ip[6]^ip[10]^ip[13]^ip[14]^ip[16]^ip[18]^ip[19]^ip[20]^ip[21]^ip[23]^ip[24]^ip[26]^ip[27]^ip[28]^ip[29]^ip[30],
                 datout[318] = ip[1]^ip[3]^ip[5]^ip[6]^ip[12]^ip[13]^ip[15]^ip[17]^ip[19]^ip[22]^ip[23]^ip[25]^ip[27]^ip[28]^ip[29]^ip[31],
                 datout[319] = ip[0]^ip[2]^ip[4]^ip[5]^ip[11]^ip[12]^ip[14]^ip[16]^ip[18]^ip[21]^ip[22]^ip[24]^ip[26]^ip[27]^ip[28]^ip[30],
                 datout[320] = ip[1]^ip[3]^ip[4]^ip[6]^ip[9]^ip[10]^ip[11]^ip[13]^ip[15]^ip[17]^ip[18]^ip[21]^ip[23]^ip[25]^ip[27]^ip[29]^ip[31],
                 datout[321] = ip[0]^ip[2]^ip[3]^ip[5]^ip[8]^ip[9]^ip[10]^ip[12]^ip[14]^ip[16]^ip[17]^ip[20]^ip[22]^ip[24]^ip[26]^ip[28]^ip[30],
                 datout[322] = ip[1]^ip[2]^ip[4]^ip[6]^ip[7]^ip[8]^ip[11]^ip[13]^ip[15]^ip[16]^ip[18]^ip[19]^ip[20]^ip[21]^ip[23]^ip[25]^ip[26]^ip[27]^ip[29]^ip[31],
                 datout[323] = ip[0]^ip[1]^ip[3]^ip[5]^ip[6]^ip[7]^ip[10]^ip[12]^ip[14]^ip[15]^ip[17]^ip[18]^ip[19]^ip[20]^ip[22]^ip[24]^ip[25]^ip[26]^ip[28]^ip[30],
                 datout[324] = ip[0]^ip[2]^ip[4]^ip[5]^ip[11]^ip[13]^ip[14]^ip[16]^ip[17]^ip[19]^ip[20]^ip[21]^ip[23]^ip[24]^ip[25]^ip[26]^ip[27]^ip[29]^ip[31],
                 datout[325] = ip[1]^ip[3]^ip[4]^ip[6]^ip[9]^ip[10]^ip[12]^ip[13]^ip[15]^ip[16]^ip[19]^ip[22]^ip[23]^ip[24]^ip[25]^ip[28]^ip[30]^ip[31],
                 datout[326] = ip[0]^ip[2]^ip[3]^ip[5]^ip[8]^ip[9]^ip[11]^ip[12]^ip[14]^ip[15]^ip[18]^ip[21]^ip[22]^ip[23]^ip[24]^ip[27]^ip[29]^ip[30],
                 datout[327] = ip[1]^ip[2]^ip[4]^ip[6]^ip[7]^ip[8]^ip[9]^ip[10]^ip[11]^ip[13]^ip[14]^ip[17]^ip[18]^ip[21]^ip[22]^ip[23]^ip[28]^ip[29]^ip[31],
                 datout[328] = ip[0]^ip[1]^ip[3]^ip[5]^ip[6]^ip[7]^ip[8]^ip[9]^ip[10]^ip[12]^ip[13]^ip[16]^ip[17]^ip[20]^ip[21]^ip[22]^ip[27]^ip[28]^ip[30],
                 datout[329] = ip[0]^ip[2]^ip[4]^ip[5]^ip[7]^ip[8]^ip[11]^ip[12]^ip[15]^ip[16]^ip[18]^ip[19]^ip[21]^ip[27]^ip[29]^ip[31],
                 datout[330] = ip[1]^ip[3]^ip[4]^ip[7]^ip[9]^ip[10]^ip[11]^ip[14]^ip[15]^ip[17]^ip[28]^ip[30]^ip[31],
                 datout[331] = ip[0]^ip[2]^ip[3]^ip[6]^ip[8]^ip[9]^ip[10]^ip[13]^ip[14]^ip[16]^ip[27]^ip[29]^ip[30],
                 datout[332] = ip[1]^ip[2]^ip[5]^ip[6]^ip[7]^ip[8]^ip[12]^ip[13]^ip[15]^ip[18]^ip[20]^ip[28]^ip[29]^ip[31],
                 datout[333] = ip[0]^ip[1]^ip[4]^ip[5]^ip[6]^ip[7]^ip[11]^ip[12]^ip[14]^ip[17]^ip[19]^ip[27]^ip[28]^ip[30],
                 datout[334] = ip[0]^ip[3]^ip[4]^ip[5]^ip[9]^ip[10]^ip[11]^ip[13]^ip[16]^ip[20]^ip[27]^ip[29]^ip[31],
                 datout[335] = ip[2]^ip[3]^ip[4]^ip[6]^ip[8]^ip[10]^ip[12]^ip[15]^ip[18]^ip[19]^ip[20]^ip[28]^ip[30]^ip[31],
                 datout[336] = ip[1]^ip[2]^ip[3]^ip[5]^ip[7]^ip[9]^ip[11]^ip[14]^ip[17]^ip[18]^ip[19]^ip[27]^ip[29]^ip[30],
                 datout[337] = ip[0]^ip[1]^ip[2]^ip[4]^ip[6]^ip[8]^ip[10]^ip[13]^ip[16]^ip[17]^ip[18]^ip[26]^ip[28]^ip[29],
                 datout[338] = ip[0]^ip[1]^ip[3]^ip[5]^ip[6]^ip[7]^ip[12]^ip[15]^ip[16]^ip[17]^ip[18]^ip[20]^ip[25]^ip[26]^ip[27]^ip[28]^ip[31],
                 datout[339] = ip[0]^ip[2]^ip[4]^ip[5]^ip[9]^ip[11]^ip[14]^ip[15]^ip[16]^ip[17]^ip[18]^ip[19]^ip[20]^ip[24]^ip[25]^ip[27]^ip[30]^ip[31],
                 datout[340] = ip[1]^ip[3]^ip[4]^ip[6]^ip[8]^ip[9]^ip[10]^ip[13]^ip[14]^ip[15]^ip[16]^ip[17]^ip[19]^ip[20]^ip[23]^ip[24]^ip[29]^ip[30]^ip[31],
                 datout[341] = ip[0]^ip[2]^ip[3]^ip[5]^ip[7]^ip[8]^ip[9]^ip[12]^ip[13]^ip[14]^ip[15]^ip[16]^ip[18]^ip[19]^ip[22]^ip[23]^ip[28]^ip[29]^ip[30],
                 datout[342] = ip[1]^ip[2]^ip[4]^ip[7]^ip[8]^ip[9]^ip[11]^ip[12]^ip[13]^ip[14]^ip[15]^ip[17]^ip[20]^ip[21]^ip[22]^ip[26]^ip[27]^ip[28]^ip[29]^ip[31],
                 datout[343] = ip[0]^ip[1]^ip[3]^ip[6]^ip[7]^ip[8]^ip[10]^ip[11]^ip[12]^ip[13]^ip[14]^ip[16]^ip[19]^ip[20]^ip[21]^ip[25]^ip[26]^ip[27]^ip[28]^ip[30],
                 datout[344] = ip[0]^ip[2]^ip[5]^ip[7]^ip[10]^ip[11]^ip[12]^ip[13]^ip[15]^ip[19]^ip[24]^ip[25]^ip[27]^ip[29]^ip[31],
                 datout[345] = ip[1]^ip[4]^ip[10]^ip[11]^ip[12]^ip[14]^ip[20]^ip[23]^ip[24]^ip[28]^ip[30]^ip[31],
                 datout[346] = ip[0]^ip[3]^ip[9]^ip[10]^ip[11]^ip[13]^ip[19]^ip[22]^ip[23]^ip[27]^ip[29]^ip[30],
                 datout[347] = ip[2]^ip[6]^ip[8]^ip[10]^ip[12]^ip[20]^ip[21]^ip[22]^ip[28]^ip[29]^ip[31],
                 datout[348] = ip[1]^ip[5]^ip[7]^ip[9]^ip[11]^ip[19]^ip[20]^ip[21]^ip[27]^ip[28]^ip[30],
                 datout[349] = ip[0]^ip[4]^ip[6]^ip[8]^ip[10]^ip[18]^ip[19]^ip[20]^ip[26]^ip[27]^ip[29],
                 datout[350] = ip[3]^ip[5]^ip[6]^ip[7]^ip[17]^ip[19]^ip[20]^ip[25]^ip[28]^ip[31],
                 datout[351] = ip[2]^ip[4]^ip[5]^ip[6]^ip[16]^ip[18]^ip[19]^ip[24]^ip[27]^ip[30],
                 datout[352] = ip[1]^ip[3]^ip[4]^ip[5]^ip[15]^ip[17]^ip[18]^ip[23]^ip[26]^ip[29],
                 datout[353] = ip[0]^ip[2]^ip[3]^ip[4]^ip[14]^ip[16]^ip[17]^ip[22]^ip[25]^ip[28],
                 datout[354] = ip[1]^ip[2]^ip[3]^ip[6]^ip[9]^ip[13]^ip[15]^ip[16]^ip[18]^ip[20]^ip[21]^ip[24]^ip[26]^ip[27]^ip[31],
                 datout[355] = ip[0]^ip[1]^ip[2]^ip[5]^ip[8]^ip[12]^ip[14]^ip[15]^ip[17]^ip[19]^ip[20]^ip[23]^ip[25]^ip[26]^ip[30],
                 datout[356] = ip[0]^ip[1]^ip[4]^ip[6]^ip[7]^ip[9]^ip[11]^ip[13]^ip[14]^ip[16]^ip[19]^ip[20]^ip[22]^ip[24]^ip[25]^ip[26]^ip[29]^ip[31],
                 datout[357] = ip[0]^ip[3]^ip[5]^ip[8]^ip[9]^ip[10]^ip[12]^ip[13]^ip[15]^ip[19]^ip[20]^ip[21]^ip[23]^ip[24]^ip[25]^ip[26]^ip[28]^ip[30]^ip[31],
                 datout[358] = ip[2]^ip[4]^ip[6]^ip[7]^ip[8]^ip[11]^ip[12]^ip[14]^ip[19]^ip[22]^ip[23]^ip[24]^ip[25]^ip[26]^ip[27]^ip[29]^ip[30]^ip[31],
                 datout[359] = ip[1]^ip[3]^ip[5]^ip[6]^ip[7]^ip[10]^ip[11]^ip[13]^ip[18]^ip[21]^ip[22]^ip[23]^ip[24]^ip[25]^ip[26]^ip[28]^ip[29]^ip[30],
                 datout[360] = ip[0]^ip[2]^ip[4]^ip[5]^ip[6]^ip[9]^ip[10]^ip[12]^ip[17]^ip[20]^ip[21]^ip[22]^ip[23]^ip[24]^ip[25]^ip[27]^ip[28]^ip[29],
                 datout[361] = ip[1]^ip[3]^ip[4]^ip[5]^ip[6]^ip[8]^ip[11]^ip[16]^ip[18]^ip[19]^ip[21]^ip[22]^ip[23]^ip[24]^ip[27]^ip[28]^ip[31],
                 datout[362] = ip[0]^ip[2]^ip[3]^ip[4]^ip[5]^ip[7]^ip[10]^ip[15]^ip[17]^ip[18]^ip[20]^ip[21]^ip[22]^ip[23]^ip[26]^ip[27]^ip[30],
                 datout[363] = ip[1]^ip[2]^ip[3]^ip[4]^ip[14]^ip[16]^ip[17]^ip[18]^ip[19]^ip[21]^ip[22]^ip[25]^ip[29]^ip[31],
                 datout[364] = ip[0]^ip[1]^ip[2]^ip[3]^ip[13]^ip[15]^ip[16]^ip[17]^ip[18]^ip[20]^ip[21]^ip[24]^ip[28]^ip[30],
                 datout[365] = ip[0]^ip[1]^ip[2]^ip[6]^ip[9]^ip[12]^ip[14]^ip[15]^ip[16]^ip[17]^ip[18]^ip[19]^ip[23]^ip[26]^ip[27]^ip[29]^ip[31],
                 datout[366] = ip[0]^ip[1]^ip[5]^ip[6]^ip[8]^ip[9]^ip[11]^ip[13]^ip[14]^ip[15]^ip[16]^ip[17]^ip[20]^ip[22]^ip[25]^ip[28]^ip[30]^ip[31],
                 datout[367] = ip[0]^ip[4]^ip[5]^ip[6]^ip[7]^ip[8]^ip[9]^ip[10]^ip[12]^ip[13]^ip[14]^ip[15]^ip[16]^ip[18]^ip[19]^ip[20]^ip[21]^ip[24]^ip[26]^ip[27]^ip[29]^
                         ip[30]^ip[31],
                 datout[368] = ip[3]^ip[4]^ip[5]^ip[7]^ip[8]^ip[11]^ip[12]^ip[13]^ip[14]^ip[15]^ip[17]^ip[19]^ip[23]^ip[25]^ip[28]^ip[29]^ip[30]^ip[31],
                 datout[369] = ip[2]^ip[3]^ip[4]^ip[6]^ip[7]^ip[10]^ip[11]^ip[12]^ip[13]^ip[14]^ip[16]^ip[18]^ip[22]^ip[24]^ip[27]^ip[28]^ip[29]^ip[30],
                 datout[370] = ip[1]^ip[2]^ip[3]^ip[5]^ip[6]^ip[9]^ip[10]^ip[11]^ip[12]^ip[13]^ip[15]^ip[17]^ip[21]^ip[23]^ip[26]^ip[27]^ip[28]^ip[29],
                 datout[371] = ip[0]^ip[1]^ip[2]^ip[4]^ip[5]^ip[8]^ip[9]^ip[10]^ip[11]^ip[12]^ip[14]^ip[16]^ip[20]^ip[22]^ip[25]^ip[26]^ip[27]^ip[28],
                 datout[372] = ip[0]^ip[1]^ip[3]^ip[4]^ip[6]^ip[7]^ip[8]^ip[10]^ip[11]^ip[13]^ip[15]^ip[18]^ip[19]^ip[20]^ip[21]^ip[24]^ip[25]^ip[27]^ip[31],
                 datout[373] = ip[0]^ip[2]^ip[3]^ip[5]^ip[7]^ip[10]^ip[12]^ip[14]^ip[17]^ip[19]^ip[23]^ip[24]^ip[30]^ip[31],
                 datout[374] = ip[1]^ip[2]^ip[4]^ip[11]^ip[13]^ip[16]^ip[20]^ip[22]^ip[23]^ip[26]^ip[29]^ip[30]^ip[31],
                 datout[375] = ip[0]^ip[1]^ip[3]^ip[10]^ip[12]^ip[15]^ip[19]^ip[21]^ip[22]^ip[25]^ip[28]^ip[29]^ip[30],
                 datout[376] = ip[0]^ip[2]^ip[6]^ip[11]^ip[14]^ip[21]^ip[24]^ip[26]^ip[27]^ip[28]^ip[29]^ip[31],
                 datout[377] = ip[1]^ip[5]^ip[6]^ip[9]^ip[10]^ip[13]^ip[18]^ip[23]^ip[25]^ip[27]^ip[28]^ip[30]^ip[31],
                 datout[378] = ip[0]^ip[4]^ip[5]^ip[8]^ip[9]^ip[12]^ip[17]^ip[22]^ip[24]^ip[26]^ip[27]^ip[29]^ip[30],
                 datout[379] = ip[3]^ip[4]^ip[6]^ip[7]^ip[8]^ip[9]^ip[11]^ip[16]^ip[18]^ip[20]^ip[21]^ip[23]^ip[25]^ip[28]^ip[29]^ip[31],
                 datout[380] = ip[2]^ip[3]^ip[5]^ip[6]^ip[7]^ip[8]^ip[10]^ip[15]^ip[17]^ip[19]^ip[20]^ip[22]^ip[24]^ip[27]^ip[28]^ip[30],
                 datout[381] = ip[1]^ip[2]^ip[4]^ip[5]^ip[6]^ip[7]^ip[9]^ip[14]^ip[16]^ip[18]^ip[19]^ip[21]^ip[23]^ip[26]^ip[27]^ip[29],
                 datout[382] = ip[0]^ip[1]^ip[3]^ip[4]^ip[5]^ip[6]^ip[8]^ip[13]^ip[15]^ip[17]^ip[18]^ip[20]^ip[22]^ip[25]^ip[26]^ip[28],
                 datout[383] = ip[0]^ip[2]^ip[3]^ip[4]^ip[5]^ip[6]^ip[7]^ip[9]^ip[12]^ip[14]^ip[16]^ip[17]^ip[18]^ip[19]^ip[20]^ip[21]^ip[24]^ip[25]^ip[26]^ip[27]^ip[31],
                 datout[384] = ip[1]^ip[2]^ip[3]^ip[4]^ip[5]^ip[8]^ip[9]^ip[11]^ip[13]^ip[15]^ip[16]^ip[17]^ip[19]^ip[23]^ip[24]^ip[25]^ip[30]^ip[31],
                 datout[385] = ip[0]^ip[1]^ip[2]^ip[3]^ip[4]^ip[7]^ip[8]^ip[10]^ip[12]^ip[14]^ip[15]^ip[16]^ip[18]^ip[22]^ip[23]^ip[24]^ip[29]^ip[30],
                 datout[386] = ip[0]^ip[1]^ip[2]^ip[3]^ip[7]^ip[11]^ip[13]^ip[14]^ip[15]^ip[17]^ip[18]^ip[20]^ip[21]^ip[22]^ip[23]^ip[26]^ip[28]^ip[29]^ip[31],
                 datout[387] = ip[0]^ip[1]^ip[2]^ip[9]^ip[10]^ip[12]^ip[13]^ip[14]^ip[16]^ip[17]^ip[18]^ip[19]^ip[21]^ip[22]^ip[25]^ip[26]^ip[27]^ip[28]^ip[30]^ip[31],
                 datout[388] = ip[0]^ip[1]^ip[6]^ip[8]^ip[11]^ip[12]^ip[13]^ip[15]^ip[16]^ip[17]^ip[21]^ip[24]^ip[25]^ip[27]^ip[29]^ip[30]^ip[31],
                 datout[389] = ip[0]^ip[5]^ip[6]^ip[7]^ip[9]^ip[10]^ip[11]^ip[12]^ip[14]^ip[15]^ip[16]^ip[18]^ip[23]^ip[24]^ip[28]^ip[29]^ip[30]^ip[31],
                 datout[390] = ip[4]^ip[5]^ip[8]^ip[10]^ip[11]^ip[13]^ip[14]^ip[15]^ip[17]^ip[18]^ip[20]^ip[22]^ip[23]^ip[26]^ip[27]^ip[28]^ip[29]^ip[30]^ip[31],
                 datout[391] = ip[3]^ip[4]^ip[7]^ip[9]^ip[10]^ip[12]^ip[13]^ip[14]^ip[16]^ip[17]^ip[19]^ip[21]^ip[22]^ip[25]^ip[26]^ip[27]^ip[28]^ip[29]^ip[30],
                 datout[392] = ip[2]^ip[3]^ip[6]^ip[8]^ip[9]^ip[11]^ip[12]^ip[13]^ip[15]^ip[16]^ip[18]^ip[20]^ip[21]^ip[24]^ip[25]^ip[26]^ip[27]^ip[28]^ip[29],
                 datout[393] = ip[1]^ip[2]^ip[5]^ip[7]^ip[8]^ip[10]^ip[11]^ip[12]^ip[14]^ip[15]^ip[17]^ip[19]^ip[20]^ip[23]^ip[24]^ip[25]^ip[26]^ip[27]^ip[28],
                 datout[394] = ip[0]^ip[1]^ip[4]^ip[6]^ip[7]^ip[9]^ip[10]^ip[11]^ip[13]^ip[14]^ip[16]^ip[18]^ip[19]^ip[22]^ip[23]^ip[24]^ip[25]^ip[26]^ip[27],
                 datout[395] = ip[0]^ip[3]^ip[5]^ip[8]^ip[10]^ip[12]^ip[13]^ip[15]^ip[17]^ip[20]^ip[21]^ip[22]^ip[23]^ip[24]^ip[25]^ip[31],
                 datout[396] = ip[2]^ip[4]^ip[6]^ip[7]^ip[11]^ip[12]^ip[14]^ip[16]^ip[18]^ip[19]^ip[21]^ip[22]^ip[23]^ip[24]^ip[26]^ip[30]^ip[31],
                 datout[397] = ip[1]^ip[3]^ip[5]^ip[6]^ip[10]^ip[11]^ip[13]^ip[15]^ip[17]^ip[18]^ip[20]^ip[21]^ip[22]^ip[23]^ip[25]^ip[29]^ip[30],
                 datout[398] = ip[0]^ip[2]^ip[4]^ip[5]^ip[9]^ip[10]^ip[12]^ip[14]^ip[16]^ip[17]^ip[19]^ip[20]^ip[21]^ip[22]^ip[24]^ip[28]^ip[29],
                 datout[399] = ip[1]^ip[3]^ip[4]^ip[6]^ip[8]^ip[11]^ip[13]^ip[15]^ip[16]^ip[19]^ip[21]^ip[23]^ip[26]^ip[27]^ip[28]^ip[31],
                 datout[400] = ip[0]^ip[2]^ip[3]^ip[5]^ip[7]^ip[10]^ip[12]^ip[14]^ip[15]^ip[18]^ip[20]^ip[22]^ip[25]^ip[26]^ip[27]^ip[30],
                 datout[401] = ip[1]^ip[2]^ip[4]^ip[11]^ip[13]^ip[14]^ip[17]^ip[18]^ip[19]^ip[20]^ip[21]^ip[24]^ip[25]^ip[29]^ip[31],
                 datout[402] = ip[0]^ip[1]^ip[3]^ip[10]^ip[12]^ip[13]^ip[16]^ip[17]^ip[18]^ip[19]^ip[20]^ip[23]^ip[24]^ip[28]^ip[30],
                 datout[403] = ip[0]^ip[2]^ip[6]^ip[11]^ip[12]^ip[15]^ip[16]^ip[17]^ip[19]^ip[20]^ip[22]^ip[23]^ip[26]^ip[27]^ip[29]^ip[31],
                 datout[404] = ip[1]^ip[5]^ip[6]^ip[9]^ip[10]^ip[11]^ip[14]^ip[15]^ip[16]^ip[19]^ip[20]^ip[21]^ip[22]^ip[25]^ip[28]^ip[30]^ip[31],
                 datout[405] = ip[0]^ip[4]^ip[5]^ip[8]^ip[9]^ip[10]^ip[13]^ip[14]^ip[15]^ip[18]^ip[19]^ip[20]^ip[21]^ip[24]^ip[27]^ip[29]^ip[30],
                 datout[406] = ip[3]^ip[4]^ip[6]^ip[7]^ip[8]^ip[12]^ip[13]^ip[14]^ip[17]^ip[19]^ip[23]^ip[28]^ip[29]^ip[31],
                 datout[407] = ip[2]^ip[3]^ip[5]^ip[6]^ip[7]^ip[11]^ip[12]^ip[13]^ip[16]^ip[18]^ip[22]^ip[27]^ip[28]^ip[30],
                 datout[408] = ip[1]^ip[2]^ip[4]^ip[5]^ip[6]^ip[10]^ip[11]^ip[12]^ip[15]^ip[17]^ip[21]^ip[26]^ip[27]^ip[29],
                 datout[409] = ip[0]^ip[1]^ip[3]^ip[4]^ip[5]^ip[9]^ip[10]^ip[11]^ip[14]^ip[16]^ip[20]^ip[25]^ip[26]^ip[28],
                 datout[410] = ip[0]^ip[2]^ip[3]^ip[4]^ip[6]^ip[8]^ip[10]^ip[13]^ip[15]^ip[18]^ip[19]^ip[20]^ip[24]^ip[25]^ip[26]^ip[27]^ip[31],
                 datout[411] = ip[1]^ip[2]^ip[3]^ip[5]^ip[6]^ip[7]^ip[12]^ip[14]^ip[17]^ip[19]^ip[20]^ip[23]^ip[24]^ip[25]^ip[30]^ip[31],
                 datout[412] = ip[0]^ip[1]^ip[2]^ip[4]^ip[5]^ip[6]^ip[11]^ip[13]^ip[16]^ip[18]^ip[19]^ip[22]^ip[23]^ip[24]^ip[29]^ip[30],
                 datout[413] = ip[0]^ip[1]^ip[3]^ip[4]^ip[5]^ip[6]^ip[9]^ip[10]^ip[12]^ip[15]^ip[17]^ip[20]^ip[21]^ip[22]^ip[23]^ip[26]^ip[28]^ip[29]^ip[31],
                 datout[414] = ip[0]^ip[2]^ip[3]^ip[4]^ip[5]^ip[6]^ip[8]^ip[11]^ip[14]^ip[16]^ip[18]^ip[19]^ip[21]^ip[22]^ip[25]^ip[26]^ip[27]^ip[28]^ip[30]^ip[31],
                 datout[415] = ip[1]^ip[2]^ip[3]^ip[4]^ip[5]^ip[6]^ip[7]^ip[9]^ip[10]^ip[13]^ip[15]^ip[17]^ip[21]^ip[24]^ip[25]^ip[27]^ip[29]^ip[30]^ip[31],
                 datout[416] = ip[0]^ip[1]^ip[2]^ip[3]^ip[4]^ip[5]^ip[6]^ip[8]^ip[9]^ip[12]^ip[14]^ip[16]^ip[20]^ip[23]^ip[24]^ip[26]^ip[28]^ip[29]^ip[30],
                 datout[417] = ip[0]^ip[1]^ip[2]^ip[3]^ip[4]^ip[5]^ip[6]^ip[7]^ip[8]^ip[9]^ip[11]^ip[13]^ip[15]^ip[18]^ip[19]^ip[20]^ip[22]^ip[23]^ip[25]^ip[26]^ip[27]^
                         ip[28]^ip[29]^ip[31],
                 datout[418] = ip[0]^ip[1]^ip[2]^ip[3]^ip[4]^ip[5]^ip[7]^ip[8]^ip[9]^ip[10]^ip[12]^ip[14]^ip[17]^ip[19]^ip[20]^ip[21]^ip[22]^ip[24]^ip[25]^ip[27]^ip[28]^
                         ip[30]^ip[31],
                 datout[419] = ip[0]^ip[1]^ip[2]^ip[3]^ip[4]^ip[7]^ip[8]^ip[11]^ip[13]^ip[16]^ip[19]^ip[21]^ip[23]^ip[24]^ip[27]^ip[29]^ip[30]^ip[31],
                 datout[420] = ip[0]^ip[1]^ip[2]^ip[3]^ip[7]^ip[9]^ip[10]^ip[12]^ip[15]^ip[22]^ip[23]^ip[28]^ip[29]^ip[30]^ip[31],
                 datout[421] = ip[0]^ip[1]^ip[2]^ip[8]^ip[11]^ip[14]^ip[18]^ip[20]^ip[21]^ip[22]^ip[26]^ip[27]^ip[28]^ip[29]^ip[30]^ip[31],
                 datout[422] = ip[0]^ip[1]^ip[6]^ip[7]^ip[9]^ip[10]^ip[13]^ip[17]^ip[18]^ip[19]^ip[21]^ip[25]^ip[27]^ip[28]^ip[29]^ip[30]^ip[31],
                 datout[423] = ip[0]^ip[5]^ip[8]^ip[12]^ip[16]^ip[17]^ip[24]^ip[27]^ip[28]^ip[29]^ip[30]^ip[31],
                 datout[424] = ip[4]^ip[6]^ip[7]^ip[9]^ip[11]^ip[15]^ip[16]^ip[18]^ip[20]^ip[23]^ip[27]^ip[28]^ip[29]^ip[30]^ip[31],
                 datout[425] = ip[3]^ip[5]^ip[6]^ip[8]^ip[10]^ip[14]^ip[15]^ip[17]^ip[19]^ip[22]^ip[26]^ip[27]^ip[28]^ip[29]^ip[30],
                 datout[426] = ip[2]^ip[4]^ip[5]^ip[7]^ip[9]^ip[13]^ip[14]^ip[16]^ip[18]^ip[21]^ip[25]^ip[26]^ip[27]^ip[28]^ip[29],
                 datout[427] = ip[1]^ip[3]^ip[4]^ip[6]^ip[8]^ip[12]^ip[13]^ip[15]^ip[17]^ip[20]^ip[24]^ip[25]^ip[26]^ip[27]^ip[28],
                 datout[428] = ip[0]^ip[2]^ip[3]^ip[5]^ip[7]^ip[11]^ip[12]^ip[14]^ip[16]^ip[19]^ip[23]^ip[24]^ip[25]^ip[26]^ip[27],
                 datout[429] = ip[1]^ip[2]^ip[4]^ip[9]^ip[10]^ip[11]^ip[13]^ip[15]^ip[20]^ip[22]^ip[23]^ip[24]^ip[25]^ip[31],
                 datout[430] = ip[0]^ip[1]^ip[3]^ip[8]^ip[9]^ip[10]^ip[12]^ip[14]^ip[19]^ip[21]^ip[22]^ip[23]^ip[24]^ip[30],
                 datout[431] = ip[0]^ip[2]^ip[6]^ip[7]^ip[8]^ip[11]^ip[13]^ip[21]^ip[22]^ip[23]^ip[26]^ip[29]^ip[31],
                 datout[432] = ip[1]^ip[5]^ip[7]^ip[9]^ip[10]^ip[12]^ip[18]^ip[21]^ip[22]^ip[25]^ip[26]^ip[28]^ip[30]^ip[31],
                 datout[433] = ip[0]^ip[4]^ip[6]^ip[8]^ip[9]^ip[11]^ip[17]^ip[20]^ip[21]^ip[24]^ip[25]^ip[27]^ip[29]^ip[30],
                 datout[434] = ip[3]^ip[5]^ip[6]^ip[7]^ip[8]^ip[9]^ip[10]^ip[16]^ip[18]^ip[19]^ip[23]^ip[24]^ip[28]^ip[29]^ip[31],
                 datout[435] = ip[2]^ip[4]^ip[5]^ip[6]^ip[7]^ip[8]^ip[9]^ip[15]^ip[17]^ip[18]^ip[22]^ip[23]^ip[27]^ip[28]^ip[30],
                 datout[436] = ip[1]^ip[3]^ip[4]^ip[5]^ip[6]^ip[7]^ip[8]^ip[14]^ip[16]^ip[17]^ip[21]^ip[22]^ip[26]^ip[27]^ip[29],
                 datout[437] = ip[0]^ip[2]^ip[3]^ip[4]^ip[5]^ip[6]^ip[7]^ip[13]^ip[15]^ip[16]^ip[20]^ip[21]^ip[25]^ip[26]^ip[28],
                 datout[438] = ip[1]^ip[2]^ip[3]^ip[4]^ip[5]^ip[9]^ip[12]^ip[14]^ip[15]^ip[18]^ip[19]^ip[24]^ip[25]^ip[26]^ip[27]^ip[31],
                 datout[439] = ip[0]^ip[1]^ip[2]^ip[3]^ip[4]^ip[8]^ip[11]^ip[13]^ip[14]^ip[17]^ip[18]^ip[23]^ip[24]^ip[25]^ip[26]^ip[30],
                 datout[440] = ip[0]^ip[1]^ip[2]^ip[3]^ip[6]^ip[7]^ip[9]^ip[10]^ip[12]^ip[13]^ip[16]^ip[17]^ip[18]^ip[20]^ip[22]^ip[23]^ip[24]^ip[25]^ip[26]^ip[29]^ip[31],
                 datout[441] = ip[0]^ip[1]^ip[2]^ip[5]^ip[8]^ip[11]^ip[12]^ip[15]^ip[16]^ip[17]^ip[18]^ip[19]^ip[20]^ip[21]^ip[22]^ip[23]^ip[24]^ip[25]^ip[26]^ip[28]^
                         ip[30]^ip[31],
                 datout[442] = ip[0]^ip[1]^ip[4]^ip[6]^ip[7]^ip[9]^ip[10]^ip[11]^ip[14]^ip[15]^ip[16]^ip[17]^ip[19]^ip[21]^ip[22]^ip[23]^ip[24]^ip[25]^ip[26]^ip[27]^ip[29]^
                         ip[30]^ip[31],
                 datout[443] = ip[0]^ip[3]^ip[5]^ip[8]^ip[10]^ip[13]^ip[14]^ip[15]^ip[16]^ip[21]^ip[22]^ip[23]^ip[24]^ip[25]^ip[28]^ip[29]^ip[30]^ip[31],
                 datout[444] = ip[2]^ip[4]^ip[6]^ip[7]^ip[12]^ip[13]^ip[14]^ip[15]^ip[18]^ip[21]^ip[22]^ip[23]^ip[24]^ip[26]^ip[27]^ip[28]^ip[29]^ip[30]^ip[31],
                 datout[445] = ip[1]^ip[3]^ip[5]^ip[6]^ip[11]^ip[12]^ip[13]^ip[14]^ip[17]^ip[20]^ip[21]^ip[22]^ip[23]^ip[25]^ip[26]^ip[27]^ip[28]^ip[29]^ip[30],
                 datout[446] = ip[0]^ip[2]^ip[4]^ip[5]^ip[10]^ip[11]^ip[12]^ip[13]^ip[16]^ip[19]^ip[20]^ip[21]^ip[22]^ip[24]^ip[25]^ip[26]^ip[27]^ip[28]^ip[29],
                 datout[447] = ip[1]^ip[3]^ip[4]^ip[6]^ip[10]^ip[11]^ip[12]^ip[15]^ip[19]^ip[21]^ip[23]^ip[24]^ip[25]^ip[27]^ip[28]^ip[31],
                 datout[448] = ip[0]^ip[2]^ip[3]^ip[5]^ip[9]^ip[10]^ip[11]^ip[14]^ip[18]^ip[20]^ip[22]^ip[23]^ip[24]^ip[26]^ip[27]^ip[30],
                 datout[449] = ip[1]^ip[2]^ip[4]^ip[6]^ip[8]^ip[10]^ip[13]^ip[17]^ip[18]^ip[19]^ip[20]^ip[21]^ip[22]^ip[23]^ip[25]^ip[29]^ip[31],
                 datout[450] = ip[0]^ip[1]^ip[3]^ip[5]^ip[7]^ip[9]^ip[12]^ip[16]^ip[17]^ip[18]^ip[19]^ip[20]^ip[21]^ip[22]^ip[24]^ip[28]^ip[30],
                 datout[451] = ip[0]^ip[2]^ip[4]^ip[8]^ip[9]^ip[11]^ip[15]^ip[16]^ip[17]^ip[19]^ip[21]^ip[23]^ip[26]^ip[27]^ip[29]^ip[31],
                 datout[452] = ip[1]^ip[3]^ip[6]^ip[7]^ip[8]^ip[9]^ip[10]^ip[14]^ip[15]^ip[16]^ip[22]^ip[25]^ip[28]^ip[30]^ip[31],
                 datout[453] = ip[0]^ip[2]^ip[5]^ip[6]^ip[7]^ip[8]^ip[9]^ip[13]^ip[14]^ip[15]^ip[21]^ip[24]^ip[27]^ip[29]^ip[30],
                 datout[454] = ip[1]^ip[4]^ip[5]^ip[7]^ip[8]^ip[9]^ip[12]^ip[13]^ip[14]^ip[18]^ip[23]^ip[28]^ip[29]^ip[31],
                 datout[455] = ip[0]^ip[3]^ip[4]^ip[6]^ip[7]^ip[8]^ip[11]^ip[12]^ip[13]^ip[17]^ip[22]^ip[27]^ip[28]^ip[30],
                 datout[456] = ip[2]^ip[3]^ip[5]^ip[7]^ip[9]^ip[10]^ip[11]^ip[12]^ip[16]^ip[18]^ip[20]^ip[21]^ip[27]^ip[29]^ip[31],
                 datout[457] = ip[1]^ip[2]^ip[4]^ip[6]^ip[8]^ip[9]^ip[10]^ip[11]^ip[15]^ip[17]^ip[19]^ip[20]^ip[26]^ip[28]^ip[30],
                 datout[458] = ip[0]^ip[1]^ip[3]^ip[5]^ip[7]^ip[8]^ip[9]^ip[10]^ip[14]^ip[16]^ip[18]^ip[19]^ip[25]^ip[27]^ip[29],
                 datout[459] = ip[0]^ip[2]^ip[4]^ip[7]^ip[8]^ip[13]^ip[15]^ip[17]^ip[20]^ip[24]^ip[28]^ip[31],
                 datout[460] = ip[1]^ip[3]^ip[7]^ip[9]^ip[12]^ip[14]^ip[16]^ip[18]^ip[19]^ip[20]^ip[23]^ip[26]^ip[27]^ip[30]^ip[31],
                 datout[461] = ip[0]^ip[2]^ip[6]^ip[8]^ip[11]^ip[13]^ip[15]^ip[17]^ip[18]^ip[19]^ip[22]^ip[25]^ip[26]^ip[29]^ip[30],
                 datout[462] = ip[1]^ip[5]^ip[6]^ip[7]^ip[9]^ip[10]^ip[12]^ip[14]^ip[16]^ip[17]^ip[20]^ip[21]^ip[24]^ip[25]^ip[26]^ip[28]^ip[29]^ip[31],
                 datout[463] = ip[0]^ip[4]^ip[5]^ip[6]^ip[8]^ip[9]^ip[11]^ip[13]^ip[15]^ip[16]^ip[19]^ip[20]^ip[23]^ip[24]^ip[25]^ip[27]^ip[28]^ip[30],
                 datout[464] = ip[3]^ip[4]^ip[5]^ip[6]^ip[7]^ip[8]^ip[9]^ip[10]^ip[12]^ip[14]^ip[15]^ip[19]^ip[20]^ip[22]^ip[23]^ip[24]^ip[27]^ip[29]^ip[31],
                 datout[465] = ip[2]^ip[3]^ip[4]^ip[5]^ip[6]^ip[7]^ip[8]^ip[9]^ip[11]^ip[13]^ip[14]^ip[18]^ip[19]^ip[21]^ip[22]^ip[23]^ip[26]^ip[28]^ip[30],
                 datout[466] = ip[1]^ip[2]^ip[3]^ip[4]^ip[5]^ip[6]^ip[7]^ip[8]^ip[10]^ip[12]^ip[13]^ip[17]^ip[18]^ip[20]^ip[21]^ip[22]^ip[25]^ip[27]^ip[29],
                 datout[467] = ip[0]^ip[1]^ip[2]^ip[3]^ip[4]^ip[5]^ip[6]^ip[7]^ip[9]^ip[11]^ip[12]^ip[16]^ip[17]^ip[19]^ip[20]^ip[21]^ip[24]^ip[26]^ip[28],
                 datout[468] = ip[0]^ip[1]^ip[2]^ip[3]^ip[4]^ip[5]^ip[8]^ip[9]^ip[10]^ip[11]^ip[15]^ip[16]^ip[19]^ip[23]^ip[25]^ip[26]^ip[27]^ip[31],
                 datout[469] = ip[0]^ip[1]^ip[2]^ip[3]^ip[4]^ip[6]^ip[7]^ip[8]^ip[10]^ip[14]^ip[15]^ip[20]^ip[22]^ip[24]^ip[25]^ip[30]^ip[31],
                 datout[470] = ip[0]^ip[1]^ip[2]^ip[3]^ip[5]^ip[7]^ip[13]^ip[14]^ip[18]^ip[19]^ip[20]^ip[21]^ip[23]^ip[24]^ip[26]^ip[29]^ip[30]^ip[31],
                 datout[471] = ip[0]^ip[1]^ip[2]^ip[4]^ip[9]^ip[12]^ip[13]^ip[17]^ip[19]^ip[22]^ip[23]^ip[25]^ip[26]^ip[28]^ip[29]^ip[30]^ip[31],
                 datout[472] = ip[0]^ip[1]^ip[3]^ip[6]^ip[8]^ip[9]^ip[11]^ip[12]^ip[16]^ip[20]^ip[21]^ip[22]^ip[24]^ip[25]^ip[26]^ip[27]^ip[28]^ip[29]^ip[30]^ip[31],
                 datout[473] = ip[0]^ip[2]^ip[5]^ip[6]^ip[7]^ip[8]^ip[9]^ip[10]^ip[11]^ip[15]^ip[18]^ip[19]^ip[21]^ip[23]^ip[24]^ip[25]^ip[27]^ip[28]^ip[29]^ip[30]^ip[31],
                 datout[474] = ip[1]^ip[4]^ip[5]^ip[7]^ip[8]^ip[10]^ip[14]^ip[17]^ip[22]^ip[23]^ip[24]^ip[27]^ip[28]^ip[29]^ip[30]^ip[31],
                 datout[475] = ip[0]^ip[3]^ip[4]^ip[6]^ip[7]^ip[9]^ip[13]^ip[16]^ip[21]^ip[22]^ip[23]^ip[26]^ip[27]^ip[28]^ip[29]^ip[30],
                 datout[476] = ip[2]^ip[3]^ip[5]^ip[8]^ip[9]^ip[12]^ip[15]^ip[18]^ip[21]^ip[22]^ip[25]^ip[27]^ip[28]^ip[29]^ip[31],
                 datout[477] = ip[1]^ip[2]^ip[4]^ip[7]^ip[8]^ip[11]^ip[14]^ip[17]^ip[20]^ip[21]^ip[24]^ip[26]^ip[27]^ip[28]^ip[30],
                 datout[478] = ip[0]^ip[1]^ip[3]^ip[6]^ip[7]^ip[10]^ip[13]^ip[16]^ip[19]^ip[20]^ip[23]^ip[25]^ip[26]^ip[27]^ip[29],
                 datout[479] = ip[0]^ip[2]^ip[5]^ip[12]^ip[15]^ip[19]^ip[20]^ip[22]^ip[24]^ip[25]^ip[28]^ip[31],
                 datout[480] = ip[1]^ip[4]^ip[6]^ip[9]^ip[11]^ip[14]^ip[19]^ip[20]^ip[21]^ip[23]^ip[24]^ip[26]^ip[27]^ip[30]^ip[31],
                 datout[481] = ip[0]^ip[3]^ip[5]^ip[8]^ip[10]^ip[13]^ip[18]^ip[19]^ip[20]^ip[22]^ip[23]^ip[25]^ip[26]^ip[29]^ip[30],
                 datout[482] = ip[2]^ip[4]^ip[6]^ip[7]^ip[12]^ip[17]^ip[19]^ip[20]^ip[21]^ip[22]^ip[24]^ip[25]^ip[26]^ip[28]^ip[29]^ip[31],
                 datout[483] = ip[1]^ip[3]^ip[5]^ip[6]^ip[11]^ip[16]^ip[18]^ip[19]^ip[20]^ip[21]^ip[23]^ip[24]^ip[25]^ip[27]^ip[28]^ip[30],
                 datout[484] = ip[0]^ip[2]^ip[4]^ip[5]^ip[10]^ip[15]^ip[17]^ip[18]^ip[19]^ip[20]^ip[22]^ip[23]^ip[24]^ip[26]^ip[27]^ip[29],
                 datout[485] = ip[1]^ip[3]^ip[4]^ip[6]^ip[14]^ip[16]^ip[17]^ip[19]^ip[20]^ip[21]^ip[22]^ip[23]^ip[25]^ip[28]^ip[31],
                 datout[486] = ip[0]^ip[2]^ip[3]^ip[5]^ip[13]^ip[15]^ip[16]^ip[18]^ip[19]^ip[20]^ip[21]^ip[22]^ip[24]^ip[27]^ip[30],
                 datout[487] = ip[1]^ip[2]^ip[4]^ip[6]^ip[9]^ip[12]^ip[14]^ip[15]^ip[17]^ip[19]^ip[21]^ip[23]^ip[29]^ip[31],
                 datout[488] = ip[0]^ip[1]^ip[3]^ip[5]^ip[8]^ip[11]^ip[13]^ip[14]^ip[16]^ip[18]^ip[20]^ip[22]^ip[28]^ip[30],
                 datout[489] = ip[0]^ip[2]^ip[4]^ip[6]^ip[7]^ip[9]^ip[10]^ip[12]^ip[13]^ip[15]^ip[17]^ip[18]^ip[19]^ip[20]^ip[21]^ip[26]^ip[27]^ip[29]^ip[31],
                 datout[490] = ip[1]^ip[3]^ip[5]^ip[8]^ip[11]^ip[12]^ip[14]^ip[16]^ip[17]^ip[19]^ip[25]^ip[28]^ip[30]^ip[31],
                 datout[491] = ip[0]^ip[2]^ip[4]^ip[7]^ip[10]^ip[11]^ip[13]^ip[15]^ip[16]^ip[18]^ip[24]^ip[27]^ip[29]^ip[30],
                 datout[492] = ip[1]^ip[3]^ip[10]^ip[12]^ip[14]^ip[15]^ip[17]^ip[18]^ip[20]^ip[23]^ip[28]^ip[29]^ip[31],
                 datout[493] = ip[0]^ip[2]^ip[9]^ip[11]^ip[13]^ip[14]^ip[16]^ip[17]^ip[19]^ip[22]^ip[27]^ip[28]^ip[30],
                 datout[494] = ip[1]^ip[6]^ip[8]^ip[9]^ip[10]^ip[12]^ip[13]^ip[15]^ip[16]^ip[20]^ip[21]^ip[27]^ip[29]^ip[31],
                 datout[495] = ip[0]^ip[5]^ip[7]^ip[8]^ip[9]^ip[11]^ip[12]^ip[14]^ip[15]^ip[19]^ip[20]^ip[26]^ip[28]^ip[30],
                 datout[496] = ip[4]^ip[7]^ip[8]^ip[9]^ip[10]^ip[11]^ip[13]^ip[14]^ip[19]^ip[20]^ip[25]^ip[26]^ip[27]^ip[29]^ip[31],
                 datout[497] = ip[3]^ip[6]^ip[7]^ip[8]^ip[9]^ip[10]^ip[12]^ip[13]^ip[18]^ip[19]^ip[24]^ip[25]^ip[26]^ip[28]^ip[30],
                 datout[498] = ip[2]^ip[5]^ip[6]^ip[7]^ip[8]^ip[9]^ip[11]^ip[12]^ip[17]^ip[18]^ip[23]^ip[24]^ip[25]^ip[27]^ip[29],
                 datout[499] = ip[1]^ip[4]^ip[5]^ip[6]^ip[7]^ip[8]^ip[10]^ip[11]^ip[16]^ip[17]^ip[22]^ip[23]^ip[24]^ip[26]^ip[28],
                 datout[500] = ip[0]^ip[3]^ip[4]^ip[5]^ip[6]^ip[7]^ip[9]^ip[10]^ip[15]^ip[16]^ip[21]^ip[22]^ip[23]^ip[25]^ip[27],
                 datout[501] = ip[2]^ip[3]^ip[4]^ip[5]^ip[8]^ip[14]^ip[15]^ip[18]^ip[21]^ip[22]^ip[24]^ip[31],
                 datout[502] = ip[1]^ip[2]^ip[3]^ip[4]^ip[7]^ip[13]^ip[14]^ip[17]^ip[20]^ip[21]^ip[23]^ip[30],
                 datout[503] = ip[0]^ip[1]^ip[2]^ip[3]^ip[6]^ip[12]^ip[13]^ip[16]^ip[19]^ip[20]^ip[22]^ip[29],
                 datout[504] = ip[0]^ip[1]^ip[2]^ip[5]^ip[6]^ip[9]^ip[11]^ip[12]^ip[15]^ip[19]^ip[20]^ip[21]^ip[26]^ip[28]^ip[31],
                 datout[505] = ip[0]^ip[1]^ip[4]^ip[5]^ip[6]^ip[8]^ip[9]^ip[10]^ip[11]^ip[14]^ip[19]^ip[25]^ip[26]^ip[27]^ip[30]^ip[31],
                 datout[506] = ip[0]^ip[3]^ip[4]^ip[5]^ip[6]^ip[7]^ip[8]^ip[10]^ip[13]^ip[20]^ip[24]^ip[25]^ip[29]^ip[30]^ip[31],
                 datout[507] = ip[2]^ip[3]^ip[4]^ip[5]^ip[7]^ip[12]^ip[18]^ip[19]^ip[20]^ip[23]^ip[24]^ip[26]^ip[28]^ip[29]^ip[30]^ip[31],
                 datout[508] = ip[1]^ip[2]^ip[3]^ip[4]^ip[6]^ip[11]^ip[17]^ip[18]^ip[19]^ip[22]^ip[23]^ip[25]^ip[27]^ip[28]^ip[29]^ip[30],
                 datout[509] = ip[0]^ip[1]^ip[2]^ip[3]^ip[5]^ip[10]^ip[16]^ip[17]^ip[18]^ip[21]^ip[22]^ip[24]^ip[26]^ip[27]^ip[28]^ip[29],
                 datout[510] = ip[0]^ip[1]^ip[2]^ip[4]^ip[6]^ip[15]^ip[16]^ip[17]^ip[18]^ip[21]^ip[23]^ip[25]^ip[27]^ip[28]^ip[31],
                 datout[511] = ip[0]^ip[1]^ip[3]^ip[5]^ip[6]^ip[9]^ip[14]^ip[15]^ip[16]^ip[17]^ip[18]^ip[22]^ip[24]^ip[27]^ip[30]^ip[31];


       end // gen_512_loop

  128: begin :gen_128_loop

         assign op[0] = ip[0]^ip[1]^ip[5]^ip[6]^ip[8]^ip[10]^ip[15]^ip[17]^ip[18]^ip[20]^ip[21]^ip[30]^ip[31],
                op[1] = ip[0]^ip[1]^ip[2]^ip[6]^ip[9]^ip[10]^ip[11]^ip[16]^ip[18]^ip[22]^ip[27]^ip[31],
                op[2] = ip[0]^ip[1]^ip[2]^ip[3]^ip[11]^ip[12]^ip[17]^ip[21]^ip[23]^ip[27]^ip[28],
                op[3] = ip[1]^ip[2]^ip[3]^ip[4]^ip[12]^ip[13]^ip[18]^ip[22]^ip[24]^ip[28]^ip[29],
                op[4] = ip[2]^ip[3]^ip[4]^ip[5]^ip[13]^ip[14]^ip[19]^ip[23]^ip[25]^ip[29]^ip[30],
                op[5] = ip[3]^ip[4]^ip[5]^ip[6]^ip[14]^ip[15]^ip[20]^ip[24]^ip[26]^ip[30]^ip[31],
                op[6] = ip[0]^ip[4]^ip[5]^ip[6]^ip[10]^ip[15]^ip[16]^ip[19]^ip[25]^ip[31],
                op[7] = ip[0]^ip[1]^ip[5]^ip[6]^ip[10]^ip[11]^ip[16]^ip[17]^ip[19]^ip[20]^ip[21]^ip[26]^ip[27],
                op[8] = ip[1]^ip[2]^ip[6]^ip[7]^ip[11]^ip[12]^ip[17]^ip[18]^ip[20]^ip[21]^ip[22]^ip[27]^ip[28],
                op[9] = ip[2]^ip[3]^ip[7]^ip[8]^ip[12]^ip[13]^ip[18]^ip[19]^ip[21]^ip[22]^ip[23]^ip[28]^ip[29],
                op[10] = ip[3]^ip[4]^ip[8]^ip[9]^ip[13]^ip[14]^ip[19]^ip[20]^ip[22]^ip[23]^ip[24]^ip[29]^ip[30],
                op[11] = ip[4]^ip[5]^ip[9]^ip[10]^ip[14]^ip[15]^ip[20]^ip[21]^ip[23]^ip[24]^ip[25]^ip[30]^ip[31],
                op[12] = ip[0]^ip[5]^ip[6]^ip[7]^ip[11]^ip[15]^ip[16]^ip[19]^ip[22]^ip[24]^ip[25]^ip[26]^ip[27]^ip[31],
                op[13] = ip[0]^ip[1]^ip[6]^ip[8]^ip[10]^ip[12]^ip[16]^ip[17]^ip[19]^ip[20]^ip[21]^ip[23]^ip[25]^ip[26]^ip[28],
                op[14] = ip[1]^ip[2]^ip[7]^ip[9]^ip[11]^ip[13]^ip[17]^ip[18]^ip[20]^ip[21]^ip[22]^ip[24]^ip[26]^ip[27]^ip[29],
                op[15] = ip[2]^ip[3]^ip[8]^ip[10]^ip[12]^ip[14]^ip[18]^ip[19]^ip[21]^ip[22]^ip[23]^ip[25]^ip[27]^ip[28]^ip[30],
                op[16] = ip[3]^ip[4]^ip[9]^ip[11]^ip[13]^ip[15]^ip[19]^ip[20]^ip[22]^ip[23]^ip[24]^ip[26]^ip[28]^ip[29]^ip[31],
                op[17] = ip[0]^ip[4]^ip[5]^ip[7]^ip[12]^ip[14]^ip[16]^ip[19]^ip[20]^ip[23]^ip[24]^ip[25]^ip[29]^ip[30],
                op[18] = ip[1]^ip[5]^ip[6]^ip[8]^ip[13]^ip[15]^ip[17]^ip[20]^ip[21]^ip[24]^ip[25]^ip[26]^ip[30]^ip[31],
                op[19] = ip[0]^ip[2]^ip[6]^ip[9]^ip[10]^ip[14]^ip[16]^ip[18]^ip[19]^ip[22]^ip[25]^ip[26]^ip[31],
                op[20] = ip[0]^ip[1]^ip[3]^ip[11]^ip[15]^ip[17]^ip[20]^ip[21]^ip[23]^ip[26],
                op[21] = ip[1]^ip[2]^ip[4]^ip[12]^ip[16]^ip[18]^ip[21]^ip[22]^ip[24]^ip[27],
                op[22] = ip[2]^ip[3]^ip[5]^ip[13]^ip[17]^ip[19]^ip[22]^ip[23]^ip[25]^ip[28],
                op[23] = ip[3]^ip[4]^ip[6]^ip[14]^ip[18]^ip[20]^ip[23]^ip[24]^ip[26]^ip[29],
                op[24] = ip[4]^ip[5]^ip[7]^ip[15]^ip[19]^ip[21]^ip[24]^ip[25]^ip[27]^ip[30],
                op[25] = ip[5]^ip[6]^ip[8]^ip[16]^ip[20]^ip[22]^ip[25]^ip[26]^ip[28]^ip[31],
                op[26] = ip[0]^ip[6]^ip[9]^ip[10]^ip[17]^ip[19]^ip[23]^ip[26]^ip[29],
                op[27] = ip[1]^ip[7]^ip[10]^ip[11]^ip[18]^ip[20]^ip[24]^ip[27]^ip[30],
                op[28] = ip[2]^ip[8]^ip[11]^ip[12]^ip[19]^ip[21]^ip[25]^ip[28]^ip[31],
                op[29] = ip[0]^ip[3]^ip[7]^ip[9]^ip[10]^ip[12]^ip[13]^ip[19]^ip[20]^ip[21]^ip[22]^ip[26]^ip[27]^ip[29],
                op[30] = ip[1]^ip[4]^ip[8]^ip[10]^ip[11]^ip[13]^ip[14]^ip[20]^ip[21]^ip[22]^ip[23]^ip[27]^ip[28]^ip[30],
                op[31] = ip[2]^ip[5]^ip[9]^ip[11]^ip[12]^ip[14]^ip[15]^ip[21]^ip[22]^ip[23]^ip[24]^ip[28]^ip[29]^ip[31];

         assign datout[0] = ip[6]^ip[9]^ip[18]^ip[20]^ip[26]^ip[31],
                datout[1] = ip[5]^ip[8]^ip[17]^ip[19]^ip[25]^ip[30],
                datout[2] = ip[4]^ip[7]^ip[16]^ip[18]^ip[24]^ip[29],
                datout[3] = ip[3]^ip[6]^ip[15]^ip[17]^ip[23]^ip[28],
                datout[4] = ip[2]^ip[5]^ip[14]^ip[16]^ip[22]^ip[27],
                datout[5] = ip[1]^ip[4]^ip[13]^ip[15]^ip[21]^ip[26],
                datout[6] = ip[0]^ip[3]^ip[12]^ip[14]^ip[20]^ip[25],
                datout[7] = ip[2]^ip[6]^ip[9]^ip[11]^ip[13]^ip[18]^ip[19]^ip[20]^ip[24]^ip[26]^ip[31],
                datout[8] = ip[1]^ip[5]^ip[8]^ip[10]^ip[12]^ip[17]^ip[18]^ip[19]^ip[23]^ip[25]^ip[30],
                datout[9] = ip[0]^ip[4]^ip[7]^ip[9]^ip[11]^ip[16]^ip[17]^ip[18]^ip[22]^ip[24]^ip[29],
                datout[10] = ip[3]^ip[8]^ip[9]^ip[10]^ip[15]^ip[16]^ip[17]^ip[18]^ip[20]^ip[21]^ip[23]^ip[26]^ip[28]^ip[31],
                datout[11] = ip[2]^ip[7]^ip[8]^ip[9]^ip[14]^ip[15]^ip[16]^ip[17]^ip[19]^ip[20]^ip[22]^ip[25]^ip[27]^ip[30],
                datout[12] = ip[1]^ip[6]^ip[7]^ip[8]^ip[13]^ip[14]^ip[15]^ip[16]^ip[18]^ip[19]^ip[21]^ip[24]^ip[26]^ip[29],
                datout[13] = ip[0]^ip[5]^ip[6]^ip[7]^ip[12]^ip[13]^ip[14]^ip[15]^ip[17]^ip[18]^ip[20]^ip[23]^ip[25]^ip[28],
                datout[14] = ip[4]^ip[5]^ip[9]^ip[11]^ip[12]^ip[13]^ip[14]^ip[16]^ip[17]^ip[18]^ip[19]^ip[20]^ip[22]^ip[24]^ip[26]^ip[27]^ip[31],
                datout[15] = ip[3]^ip[4]^ip[8]^ip[10]^ip[11]^ip[12]^ip[13]^ip[15]^ip[16]^ip[17]^ip[18]^ip[19]^ip[21]^ip[23]^ip[25]^ip[26]^ip[30],
                datout[16] = ip[2]^ip[3]^ip[7]^ip[9]^ip[10]^ip[11]^ip[12]^ip[14]^ip[15]^ip[16]^ip[17]^ip[18]^ip[20]^ip[22]^ip[24]^ip[25]^ip[29],
                datout[17] = ip[1]^ip[2]^ip[6]^ip[8]^ip[9]^ip[10]^ip[11]^ip[13]^ip[14]^ip[15]^ip[16]^ip[17]^ip[19]^ip[21]^ip[23]^ip[24]^ip[28],
                datout[18] = ip[0]^ip[1]^ip[5]^ip[7]^ip[8]^ip[9]^ip[10]^ip[12]^ip[13]^ip[14]^ip[15]^ip[16]^ip[18]^ip[20]^ip[22]^ip[23]^ip[27],
                datout[19] = ip[0]^ip[4]^ip[7]^ip[8]^ip[11]^ip[12]^ip[13]^ip[14]^ip[15]^ip[17]^ip[18]^ip[19]^ip[20]^ip[21]^ip[22]^ip[31],
                datout[20] = ip[3]^ip[7]^ip[9]^ip[10]^ip[11]^ip[12]^ip[13]^ip[14]^ip[16]^ip[17]^ip[19]^ip[21]^ip[26]^ip[30]^ip[31],
                datout[21] = ip[2]^ip[6]^ip[8]^ip[9]^ip[10]^ip[11]^ip[12]^ip[13]^ip[15]^ip[16]^ip[18]^ip[20]^ip[25]^ip[29]^ip[30],
                datout[22] = ip[1]^ip[5]^ip[7]^ip[8]^ip[9]^ip[10]^ip[11]^ip[12]^ip[14]^ip[15]^ip[17]^ip[19]^ip[24]^ip[28]^ip[29],
                datout[23] = ip[0]^ip[4]^ip[6]^ip[7]^ip[8]^ip[9]^ip[10]^ip[11]^ip[13]^ip[14]^ip[16]^ip[18]^ip[23]^ip[27]^ip[28],
                datout[24] = ip[3]^ip[5]^ip[7]^ip[8]^ip[10]^ip[12]^ip[13]^ip[15]^ip[17]^ip[18]^ip[20]^ip[22]^ip[27]^ip[31],
                datout[25] = ip[2]^ip[4]^ip[6]^ip[7]^ip[9]^ip[11]^ip[12]^ip[14]^ip[16]^ip[17]^ip[19]^ip[21]^ip[26]^ip[30],
                datout[26] = ip[1]^ip[3]^ip[5]^ip[6]^ip[8]^ip[10]^ip[11]^ip[13]^ip[15]^ip[16]^ip[18]^ip[20]^ip[25]^ip[29],
                datout[27] = ip[0]^ip[2]^ip[4]^ip[5]^ip[7]^ip[9]^ip[10]^ip[12]^ip[14]^ip[15]^ip[17]^ip[19]^ip[24]^ip[28],
                datout[28] = ip[1]^ip[3]^ip[4]^ip[8]^ip[11]^ip[13]^ip[14]^ip[16]^ip[20]^ip[23]^ip[26]^ip[27]^ip[31],
                datout[29] = ip[0]^ip[2]^ip[3]^ip[7]^ip[10]^ip[12]^ip[13]^ip[15]^ip[19]^ip[22]^ip[25]^ip[26]^ip[30],
                datout[30] = ip[1]^ip[2]^ip[11]^ip[12]^ip[14]^ip[20]^ip[21]^ip[24]^ip[25]^ip[26]^ip[29]^ip[31],
                datout[31] = ip[0]^ip[1]^ip[10]^ip[11]^ip[13]^ip[19]^ip[20]^ip[23]^ip[24]^ip[25]^ip[28]^ip[30],
                datout[32] = ip[0]^ip[6]^ip[10]^ip[12]^ip[19]^ip[20]^ip[22]^ip[23]^ip[24]^ip[26]^ip[27]^ip[29]^ip[31],
                datout[33] = ip[5]^ip[6]^ip[11]^ip[19]^ip[20]^ip[21]^ip[22]^ip[23]^ip[25]^ip[28]^ip[30]^ip[31],
                datout[34] = ip[4]^ip[5]^ip[10]^ip[18]^ip[19]^ip[20]^ip[21]^ip[22]^ip[24]^ip[27]^ip[29]^ip[30],
                datout[35] = ip[3]^ip[4]^ip[9]^ip[17]^ip[18]^ip[19]^ip[20]^ip[21]^ip[23]^ip[26]^ip[28]^ip[29],
                datout[36] = ip[2]^ip[3]^ip[8]^ip[16]^ip[17]^ip[18]^ip[19]^ip[20]^ip[22]^ip[25]^ip[27]^ip[28],
                datout[37] = ip[1]^ip[2]^ip[7]^ip[15]^ip[16]^ip[17]^ip[18]^ip[19]^ip[21]^ip[24]^ip[26]^ip[27],
                datout[38] = ip[0]^ip[1]^ip[6]^ip[14]^ip[15]^ip[16]^ip[17]^ip[18]^ip[20]^ip[23]^ip[25]^ip[26],
                datout[39] = ip[0]^ip[5]^ip[6]^ip[9]^ip[13]^ip[14]^ip[15]^ip[16]^ip[17]^ip[18]^ip[19]^ip[20]^ip[22]^ip[24]^ip[25]^ip[26]^ip[31],
                datout[40] = ip[4]^ip[5]^ip[6]^ip[8]^ip[9]^ip[12]^ip[13]^ip[14]^ip[15]^ip[16]^ip[17]^ip[19]^ip[20]^ip[21]^ip[23]^ip[24]^ip[25]^ip[26]^ip[30]^ip[31],
                datout[41] = ip[3]^ip[4]^ip[5]^ip[7]^ip[8]^ip[11]^ip[12]^ip[13]^ip[14]^ip[15]^ip[16]^ip[18]^ip[19]^ip[20]^ip[22]^ip[23]^ip[24]^ip[25]^ip[29]^ip[30],
                datout[42] = ip[2]^ip[3]^ip[4]^ip[6]^ip[7]^ip[10]^ip[11]^ip[12]^ip[13]^ip[14]^ip[15]^ip[17]^ip[18]^ip[19]^ip[21]^ip[22]^ip[23]^ip[24]^ip[28]^ip[29],
                datout[43] = ip[1]^ip[2]^ip[3]^ip[5]^ip[6]^ip[9]^ip[10]^ip[11]^ip[12]^ip[13]^ip[14]^ip[16]^ip[17]^ip[18]^ip[20]^ip[21]^ip[22]^ip[23]^ip[27]^ip[28],
                datout[44] = ip[0]^ip[1]^ip[2]^ip[4]^ip[5]^ip[8]^ip[9]^ip[10]^ip[11]^ip[12]^ip[13]^ip[15]^ip[16]^ip[17]^ip[19]^ip[20]^ip[21]^ip[22]^ip[26]^ip[27],
                datout[45] = ip[0]^ip[1]^ip[3]^ip[4]^ip[6]^ip[7]^ip[8]^ip[10]^ip[11]^ip[12]^ip[14]^ip[15]^ip[16]^ip[19]^ip[21]^ip[25]^ip[31],
                datout[46] = ip[0]^ip[2]^ip[3]^ip[5]^ip[7]^ip[10]^ip[11]^ip[13]^ip[14]^ip[15]^ip[24]^ip[26]^ip[30]^ip[31],
                datout[47] = ip[1]^ip[2]^ip[4]^ip[10]^ip[12]^ip[13]^ip[14]^ip[18]^ip[20]^ip[23]^ip[25]^ip[26]^ip[29]^ip[30]^ip[31],
                datout[48] = ip[0]^ip[1]^ip[3]^ip[9]^ip[11]^ip[12]^ip[13]^ip[17]^ip[19]^ip[22]^ip[24]^ip[25]^ip[28]^ip[29]^ip[30],
                datout[49] = ip[0]^ip[2]^ip[6]^ip[8]^ip[9]^ip[10]^ip[11]^ip[12]^ip[16]^ip[20]^ip[21]^ip[23]^ip[24]^ip[26]^ip[27]^ip[28]^ip[29]^ip[31],
                datout[50] = ip[1]^ip[5]^ip[6]^ip[7]^ip[8]^ip[10]^ip[11]^ip[15]^ip[18]^ip[19]^ip[22]^ip[23]^ip[25]^ip[27]^ip[28]^ip[30]^ip[31],
                datout[51] = ip[0]^ip[4]^ip[5]^ip[6]^ip[7]^ip[9]^ip[10]^ip[14]^ip[17]^ip[18]^ip[21]^ip[22]^ip[24]^ip[26]^ip[27]^ip[29]^ip[30],
                datout[52] = ip[3]^ip[4]^ip[5]^ip[8]^ip[13]^ip[16]^ip[17]^ip[18]^ip[21]^ip[23]^ip[25]^ip[28]^ip[29]^ip[31],
                datout[53] = ip[2]^ip[3]^ip[4]^ip[7]^ip[12]^ip[15]^ip[16]^ip[17]^ip[20]^ip[22]^ip[24]^ip[27]^ip[28]^ip[30],
                datout[54] = ip[1]^ip[2]^ip[3]^ip[6]^ip[11]^ip[14]^ip[15]^ip[16]^ip[19]^ip[21]^ip[23]^ip[26]^ip[27]^ip[29],
                datout[55] = ip[0]^ip[1]^ip[2]^ip[5]^ip[10]^ip[13]^ip[14]^ip[15]^ip[18]^ip[20]^ip[22]^ip[25]^ip[26]^ip[28],
                datout[56] = ip[0]^ip[1]^ip[4]^ip[6]^ip[12]^ip[13]^ip[14]^ip[17]^ip[18]^ip[19]^ip[20]^ip[21]^ip[24]^ip[25]^ip[26]^ip[27]^ip[31],
                datout[57] = ip[0]^ip[3]^ip[5]^ip[6]^ip[9]^ip[11]^ip[12]^ip[13]^ip[16]^ip[17]^ip[19]^ip[23]^ip[24]^ip[25]^ip[30]^ip[31],
                datout[58] = ip[2]^ip[4]^ip[5]^ip[6]^ip[8]^ip[9]^ip[10]^ip[11]^ip[12]^ip[15]^ip[16]^ip[20]^ip[22]^ip[23]^ip[24]^ip[26]^ip[29]^ip[30]^ip[31],
                datout[59] = ip[1]^ip[3]^ip[4]^ip[5]^ip[7]^ip[8]^ip[9]^ip[10]^ip[11]^ip[14]^ip[15]^ip[19]^ip[21]^ip[22]^ip[23]^ip[25]^ip[28]^ip[29]^ip[30],
                datout[60] = ip[0]^ip[2]^ip[3]^ip[4]^ip[6]^ip[7]^ip[8]^ip[9]^ip[10]^ip[13]^ip[14]^ip[18]^ip[20]^ip[21]^ip[22]^ip[24]^ip[27]^ip[28]^ip[29],
                datout[61] = ip[1]^ip[2]^ip[3]^ip[5]^ip[7]^ip[8]^ip[12]^ip[13]^ip[17]^ip[18]^ip[19]^ip[21]^ip[23]^ip[27]^ip[28]^ip[31],
                datout[62] = ip[0]^ip[1]^ip[2]^ip[4]^ip[6]^ip[7]^ip[11]^ip[12]^ip[16]^ip[17]^ip[18]^ip[20]^ip[22]^ip[26]^ip[27]^ip[30],
                datout[63] = ip[0]^ip[1]^ip[3]^ip[5]^ip[9]^ip[10]^ip[11]^ip[15]^ip[16]^ip[17]^ip[18]^ip[19]^ip[20]^ip[21]^ip[25]^ip[29]^ip[31],
                datout[64] = ip[0]^ip[2]^ip[4]^ip[6]^ip[8]^ip[10]^ip[14]^ip[15]^ip[16]^ip[17]^ip[19]^ip[24]^ip[26]^ip[28]^ip[30]^ip[31],
                datout[65] = ip[1]^ip[3]^ip[5]^ip[6]^ip[7]^ip[13]^ip[14]^ip[15]^ip[16]^ip[20]^ip[23]^ip[25]^ip[26]^ip[27]^ip[29]^ip[30]^ip[31],
                datout[66] = ip[0]^ip[2]^ip[4]^ip[5]^ip[6]^ip[12]^ip[13]^ip[14]^ip[15]^ip[19]^ip[22]^ip[24]^ip[25]^ip[26]^ip[28]^ip[29]^ip[30],
                datout[67] = ip[1]^ip[3]^ip[4]^ip[5]^ip[6]^ip[9]^ip[11]^ip[12]^ip[13]^ip[14]^ip[20]^ip[21]^ip[23]^ip[24]^ip[25]^ip[26]^ip[27]^ip[28]^ip[29]^ip[31],
                datout[68] = ip[0]^ip[2]^ip[3]^ip[4]^ip[5]^ip[8]^ip[10]^ip[11]^ip[12]^ip[13]^ip[19]^ip[20]^ip[22]^ip[23]^ip[24]^ip[25]^ip[26]^ip[27]^ip[28]^ip[30],
                datout[69] = ip[1]^ip[2]^ip[3]^ip[4]^ip[6]^ip[7]^ip[10]^ip[11]^ip[12]^ip[19]^ip[20]^ip[21]^ip[22]^ip[23]^ip[24]^ip[25]^ip[27]^ip[29]^ip[31],
                datout[70] = ip[0]^ip[1]^ip[2]^ip[3]^ip[5]^ip[6]^ip[9]^ip[10]^ip[11]^ip[18]^ip[19]^ip[20]^ip[21]^ip[22]^ip[23]^ip[24]^ip[26]^ip[28]^ip[30],
                datout[71] = ip[0]^ip[1]^ip[2]^ip[4]^ip[5]^ip[6]^ip[8]^ip[10]^ip[17]^ip[19]^ip[21]^ip[22]^ip[23]^ip[25]^ip[26]^ip[27]^ip[29]^ip[31],
                datout[72] = ip[0]^ip[1]^ip[3]^ip[4]^ip[5]^ip[6]^ip[7]^ip[16]^ip[21]^ip[22]^ip[24]^ip[25]^ip[28]^ip[30]^ip[31],
                datout[73] = ip[0]^ip[2]^ip[3]^ip[4]^ip[5]^ip[9]^ip[15]^ip[18]^ip[21]^ip[23]^ip[24]^ip[26]^ip[27]^ip[29]^ip[30]^ip[31],
                datout[74] = ip[1]^ip[2]^ip[3]^ip[4]^ip[6]^ip[8]^ip[9]^ip[14]^ip[17]^ip[18]^ip[22]^ip[23]^ip[25]^ip[28]^ip[29]^ip[30]^ip[31],
                datout[75] = ip[0]^ip[1]^ip[2]^ip[3]^ip[5]^ip[7]^ip[8]^ip[13]^ip[16]^ip[17]^ip[21]^ip[22]^ip[24]^ip[27]^ip[28]^ip[29]^ip[30],
                datout[76] = ip[0]^ip[1]^ip[2]^ip[4]^ip[7]^ip[9]^ip[12]^ip[15]^ip[16]^ip[18]^ip[21]^ip[23]^ip[27]^ip[28]^ip[29]^ip[31],
                datout[77] = ip[0]^ip[1]^ip[3]^ip[8]^ip[9]^ip[11]^ip[14]^ip[15]^ip[17]^ip[18]^ip[22]^ip[27]^ip[28]^ip[30]^ip[31],
                datout[78] = ip[0]^ip[2]^ip[6]^ip[7]^ip[8]^ip[9]^ip[10]^ip[13]^ip[14]^ip[16]^ip[17]^ip[18]^ip[20]^ip[21]^ip[27]^ip[29]^ip[30]^ip[31],
                datout[79] = ip[1]^ip[5]^ip[7]^ip[8]^ip[12]^ip[13]^ip[15]^ip[16]^ip[17]^ip[18]^ip[19]^ip[28]^ip[29]^ip[30]^ip[31],
                datout[80] = ip[0]^ip[4]^ip[6]^ip[7]^ip[11]^ip[12]^ip[14]^ip[15]^ip[16]^ip[17]^ip[18]^ip[27]^ip[28]^ip[29]^ip[30],
                datout[81] = ip[3]^ip[5]^ip[9]^ip[10]^ip[11]^ip[13]^ip[14]^ip[15]^ip[16]^ip[17]^ip[18]^ip[20]^ip[27]^ip[28]^ip[29]^ip[31],
                datout[82] = ip[2]^ip[4]^ip[8]^ip[9]^ip[10]^ip[12]^ip[13]^ip[14]^ip[15]^ip[16]^ip[17]^ip[19]^ip[26]^ip[27]^ip[28]^ip[30],
                datout[83] = ip[1]^ip[3]^ip[7]^ip[8]^ip[9]^ip[11]^ip[12]^ip[13]^ip[14]^ip[15]^ip[16]^ip[18]^ip[25]^ip[26]^ip[27]^ip[29],
                datout[84] = ip[0]^ip[2]^ip[6]^ip[7]^ip[8]^ip[10]^ip[11]^ip[12]^ip[13]^ip[14]^ip[15]^ip[17]^ip[24]^ip[25]^ip[26]^ip[28],
                datout[85] = ip[1]^ip[5]^ip[7]^ip[10]^ip[11]^ip[12]^ip[13]^ip[14]^ip[16]^ip[18]^ip[20]^ip[23]^ip[24]^ip[25]^ip[26]^ip[27]^ip[31],
                datout[86] = ip[0]^ip[4]^ip[6]^ip[9]^ip[10]^ip[11]^ip[12]^ip[13]^ip[15]^ip[17]^ip[19]^ip[22]^ip[23]^ip[24]^ip[25]^ip[26]^ip[30],
                datout[87] = ip[3]^ip[5]^ip[6]^ip[8]^ip[10]^ip[11]^ip[12]^ip[14]^ip[16]^ip[20]^ip[21]^ip[22]^ip[23]^ip[24]^ip[25]^ip[26]^ip[29]^ip[31],
                datout[88] = ip[2]^ip[4]^ip[5]^ip[7]^ip[9]^ip[10]^ip[11]^ip[13]^ip[15]^ip[19]^ip[20]^ip[21]^ip[22]^ip[23]^ip[24]^ip[25]^ip[28]^ip[30],
                datout[89] = ip[1]^ip[3]^ip[4]^ip[6]^ip[8]^ip[9]^ip[10]^ip[12]^ip[14]^ip[18]^ip[19]^ip[20]^ip[21]^ip[22]^ip[23]^ip[24]^ip[27]^ip[29],
                datout[90] = ip[0]^ip[2]^ip[3]^ip[5]^ip[7]^ip[8]^ip[9]^ip[11]^ip[13]^ip[17]^ip[18]^ip[19]^ip[20]^ip[21]^ip[22]^ip[23]^ip[26]^ip[28],
                datout[91] = ip[1]^ip[2]^ip[4]^ip[7]^ip[8]^ip[9]^ip[10]^ip[12]^ip[16]^ip[17]^ip[19]^ip[21]^ip[22]^ip[25]^ip[26]^ip[27]^ip[31],
                datout[92] = ip[0]^ip[1]^ip[3]^ip[6]^ip[7]^ip[8]^ip[9]^ip[11]^ip[15]^ip[16]^ip[18]^ip[20]^ip[21]^ip[24]^ip[25]^ip[26]^ip[30],
                datout[93] = ip[0]^ip[2]^ip[5]^ip[7]^ip[8]^ip[9]^ip[10]^ip[14]^ip[15]^ip[17]^ip[18]^ip[19]^ip[23]^ip[24]^ip[25]^ip[26]^ip[29]^ip[31],
                datout[94] = ip[1]^ip[4]^ip[7]^ip[8]^ip[13]^ip[14]^ip[16]^ip[17]^ip[20]^ip[22]^ip[23]^ip[24]^ip[25]^ip[26]^ip[28]^ip[30]^ip[31],
                datout[95] = ip[0]^ip[3]^ip[6]^ip[7]^ip[12]^ip[13]^ip[15]^ip[16]^ip[19]^ip[21]^ip[22]^ip[23]^ip[24]^ip[25]^ip[27]^ip[29]^ip[30],
                datout[96] = ip[2]^ip[5]^ip[9]^ip[11]^ip[12]^ip[14]^ip[15]^ip[21]^ip[22]^ip[23]^ip[24]^ip[28]^ip[29]^ip[31],
                datout[97] = ip[1]^ip[4]^ip[8]^ip[10]^ip[11]^ip[13]^ip[14]^ip[20]^ip[21]^ip[22]^ip[23]^ip[27]^ip[28]^ip[30],
                datout[98] = ip[0]^ip[3]^ip[7]^ip[9]^ip[10]^ip[12]^ip[13]^ip[19]^ip[20]^ip[21]^ip[22]^ip[26]^ip[27]^ip[29],
                datout[99] = ip[2]^ip[8]^ip[11]^ip[12]^ip[19]^ip[21]^ip[25]^ip[28]^ip[31],
                datout[100] = ip[1]^ip[7]^ip[10]^ip[11]^ip[18]^ip[20]^ip[24]^ip[27]^ip[30],
                datout[101] = ip[0]^ip[6]^ip[9]^ip[10]^ip[17]^ip[19]^ip[23]^ip[26]^ip[29],
                datout[102] = ip[5]^ip[6]^ip[8]^ip[16]^ip[20]^ip[22]^ip[25]^ip[26]^ip[28]^ip[31],
                datout[103] = ip[4]^ip[5]^ip[7]^ip[15]^ip[19]^ip[21]^ip[24]^ip[25]^ip[27]^ip[30],
                datout[104] = ip[3]^ip[4]^ip[6]^ip[14]^ip[18]^ip[20]^ip[23]^ip[24]^ip[26]^ip[29],
                datout[105] = ip[2]^ip[3]^ip[5]^ip[13]^ip[17]^ip[19]^ip[22]^ip[23]^ip[25]^ip[28],
                datout[106] = ip[1]^ip[2]^ip[4]^ip[12]^ip[16]^ip[18]^ip[21]^ip[22]^ip[24]^ip[27],
                datout[107] = ip[0]^ip[1]^ip[3]^ip[11]^ip[15]^ip[17]^ip[20]^ip[21]^ip[23]^ip[26],
                datout[108] = ip[0]^ip[2]^ip[6]^ip[9]^ip[10]^ip[14]^ip[16]^ip[18]^ip[19]^ip[22]^ip[25]^ip[26]^ip[31],
                datout[109] = ip[1]^ip[5]^ip[6]^ip[8]^ip[13]^ip[15]^ip[17]^ip[20]^ip[21]^ip[24]^ip[25]^ip[26]^ip[30]^ip[31],
                datout[110] = ip[0]^ip[4]^ip[5]^ip[7]^ip[12]^ip[14]^ip[16]^ip[19]^ip[20]^ip[23]^ip[24]^ip[25]^ip[29]^ip[30],
                datout[111] = ip[3]^ip[4]^ip[9]^ip[11]^ip[13]^ip[15]^ip[19]^ip[20]^ip[22]^ip[23]^ip[24]^ip[26]^ip[28]^ip[29]^ip[31],
                datout[112] = ip[2]^ip[3]^ip[8]^ip[10]^ip[12]^ip[14]^ip[18]^ip[19]^ip[21]^ip[22]^ip[23]^ip[25]^ip[27]^ip[28]^ip[30],
                datout[113] = ip[1]^ip[2]^ip[7]^ip[9]^ip[11]^ip[13]^ip[17]^ip[18]^ip[20]^ip[21]^ip[22]^ip[24]^ip[26]^ip[27]^ip[29],
                datout[114] = ip[0]^ip[1]^ip[6]^ip[8]^ip[10]^ip[12]^ip[16]^ip[17]^ip[19]^ip[20]^ip[21]^ip[23]^ip[25]^ip[26]^ip[28],
                datout[115] = ip[0]^ip[5]^ip[6]^ip[7]^ip[11]^ip[15]^ip[16]^ip[19]^ip[22]^ip[24]^ip[25]^ip[26]^ip[27]^ip[31],
                datout[116] = ip[4]^ip[5]^ip[9]^ip[10]^ip[14]^ip[15]^ip[20]^ip[21]^ip[23]^ip[24]^ip[25]^ip[30]^ip[31],
                datout[117] = ip[3]^ip[4]^ip[8]^ip[9]^ip[13]^ip[14]^ip[19]^ip[20]^ip[22]^ip[23]^ip[24]^ip[29]^ip[30],
                datout[118] = ip[2]^ip[3]^ip[7]^ip[8]^ip[12]^ip[13]^ip[18]^ip[19]^ip[21]^ip[22]^ip[23]^ip[28]^ip[29],
                datout[119] = ip[1]^ip[2]^ip[6]^ip[7]^ip[11]^ip[12]^ip[17]^ip[18]^ip[20]^ip[21]^ip[22]^ip[27]^ip[28],
                datout[120] = ip[0]^ip[1]^ip[5]^ip[6]^ip[10]^ip[11]^ip[16]^ip[17]^ip[19]^ip[20]^ip[21]^ip[26]^ip[27],
                datout[121] = ip[0]^ip[4]^ip[5]^ip[6]^ip[10]^ip[15]^ip[16]^ip[19]^ip[25]^ip[31],
                datout[122] = ip[3]^ip[4]^ip[5]^ip[6]^ip[14]^ip[15]^ip[20]^ip[24]^ip[26]^ip[30]^ip[31],
                datout[123] = ip[2]^ip[3]^ip[4]^ip[5]^ip[13]^ip[14]^ip[19]^ip[23]^ip[25]^ip[29]^ip[30],
                datout[124] = ip[1]^ip[2]^ip[3]^ip[4]^ip[12]^ip[13]^ip[18]^ip[22]^ip[24]^ip[28]^ip[29],
                datout[125] = ip[0]^ip[1]^ip[2]^ip[3]^ip[11]^ip[12]^ip[17]^ip[21]^ip[23]^ip[27]^ip[28],
                datout[126] = ip[0]^ip[1]^ip[2]^ip[6]^ip[9]^ip[10]^ip[11]^ip[16]^ip[18]^ip[22]^ip[27]^ip[31],
                datout[127] = ip[0]^ip[1]^ip[5]^ip[6]^ip[8]^ip[10]^ip[15]^ip[17]^ip[18]^ip[20]^ip[21]^ip[30]^ip[31];

       end // gen_128_loop

       default: begin :gen_rtl_loop

                  reg [(BIT_COUNT-1):0] mdat;
                  reg [REMAINDER_SIZE:0] md, nCRC [0:(BIT_COUNT-1)];                       // temp vaiables used in CRC calculation

                  always @(ip) begin :crc_loop
                    integer i;
                    nCRC[0] = {ip,^(CRC_POLYNOMIAL & {ip,1'b0})};
                    for(i=1;i<BIT_COUNT;i=i+1) begin                     // Calculate remaining CRC for all other data bits in parallel
                      md = nCRC[i-1];
                      mdat[i-1] = md[0];
                      nCRC[i] = {md,^(CRC_POLYNOMIAL & {md[(REMAINDER_SIZE-1):0],1'b0})};
                    end
                    md = nCRC[(BIT_COUNT-1)];
                    mdat[(BIT_COUNT-1)] = md[0];
                  end

                  assign op = md;                          // The output polynomial is the very last entry in the array
                  assign datout  = mdat;

                end             // gen_rtl_loop

endcase

endgenerate


endmodule
