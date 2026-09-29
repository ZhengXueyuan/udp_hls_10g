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
module pcs64_exdes
(
    input  wire gt_rxp_in_0,
    input  wire gt_rxn_in_0,
    output wire gt_txp_out_0,
    output wire gt_txn_out_0,
    input  wire restart_tx_rx_0,
    input  wire send_continous_pkts_0,   // This port can be used to send continous packets 
    output wire rx_gt_locked_led_0,     // Indicates GT LOCK
    output wire rx_block_lock_led_0,    // Indicates Core Block Lock
    output wire [4:0] completion_status,
    input             sys_reset,
    input             gt_refclk_p,
    input             gt_refclk_n,
    input             dclk
);

  parameter PKT_NUM         = 20;    //// Many Internal Counters are based on PKT_NUM = 20

  wire [2:0] gt_loopback_in_0; 

//// For other GT loopback options please change the value appropriately
//// For example, for internal loopback gt_loopback_in[2:0] = 3'b010;
//// For more information and settings on loopback, refer GT Transceivers user guide

  assign gt_loopback_in_0 = 3'b000;
                                                
  wire  block_lock_led_0;
  
  
  wire rx_core_clk_0;
  wire rx_clk_out_0;
  wire tx_mii_clk_0;
  //assign rx_core_clk_0 = tx_mii_clk_0; 
  assign rx_core_clk_0 = rx_clk_out_0;

//// RX_0 Signals
  wire rx_reset_0;
  wire user_rx_reset_0;
  wire rxrecclkout_0;

//// RX_0 User Interface Signals
  wire [63:0] rx_mii_d_0;
  wire [7:0] rx_mii_c_0;

//// RX_0 Control Signals
  wire ctl_rx_test_pattern_0;
  wire ctl_rx_test_pattern_enable_0;
  wire ctl_rx_data_pattern_select_0;
  wire ctl_rx_prbs31_test_pattern_enable_0;




//// RX_0 Stats Signals
  wire stat_rx_block_lock_0;
  wire stat_rx_framing_err_valid_0;
  wire stat_rx_framing_err_0;
  wire stat_rx_hi_ber_0;
  wire stat_rx_valid_ctrl_code_0;
  wire stat_rx_bad_code_0;
  wire stat_rx_bad_code_valid_0;
  wire stat_rx_error_valid_0;
  wire [7:0] stat_rx_error_0;
  wire stat_rx_fifo_error_0;
  wire stat_rx_local_fault_0;
   wire stat_rx_status_0;
//// TX_0 Signals
  wire tx_reset_0;
  wire user_tx_reset_0;

//// TX_0 User Interface Signals
  wire [63:0] tx_mii_d_0;
  wire [7:0] tx_mii_c_0;
//// TX_0 Control Signals
  wire ctl_tx_test_pattern_0;
  wire ctl_tx_test_pattern_enable_0;
  wire ctl_tx_test_pattern_select_0;
  wire ctl_tx_data_pattern_select_0;
  wire [57:0] ctl_tx_test_pattern_seed_a_0;
  wire [57:0] ctl_tx_test_pattern_seed_b_0;
  wire ctl_tx_prbs31_test_pattern_enable_0;


//// TX_0 Stats Signals
  wire stat_tx_local_fault_0;



   wire gtwiz_reset_tx_datapath_0;
   wire gtwiz_reset_rx_datapath_0;
   assign gtwiz_reset_tx_datapath_0 = 1'b0; 
   assign gtwiz_reset_rx_datapath_0 = 1'b0; 

   wire gtpowergood_out_0;
   wire [2:0] txoutclksel_in_0;
   wire [2:0] rxoutclksel_in_0;

   assign txoutclksel_in_0 = 3'b101;    // this value should not be changed as per gtwizard 
   assign rxoutclksel_in_0 = 3'b101;    // this value should not be changed as per gtwizard
   assign rx_block_lock_led_0 = block_lock_led_0 & stat_rx_status_0;
   wire qpllreset_in_0;
   assign qpllreset_in_0 = 1'b0;         // Changing qpllreset_in_0 value may impact or disturb other cores in case of multicore
                                         // User should take care of this while changing.
  
  wire  [4:0 ]completion_status_0;
  wire  gt_refclk_out;





  wire ctl_rx_wdt_disable_0;
  assign ctl_rx_wdt_disable_0 = 1'b0;


  
pcs64 DUT
(
    .ctl_rx_wdt_disable_0 (ctl_rx_wdt_disable_0),

    .gt_rxp_in_0 (gt_rxp_in_0),
    .gt_rxn_in_0 (gt_rxn_in_0),
    .gt_txp_out_0 (gt_txp_out_0),
    .gt_txn_out_0 (gt_txn_out_0),
    .tx_mii_clk_0 (tx_mii_clk_0),
    .rx_core_clk_0 (rx_core_clk_0),
    .rx_clk_out_0 (rx_clk_out_0),

 
    .gt_loopback_in_0 (gt_loopback_in_0),
    .rx_reset_0 (rx_reset_0),
    .user_rx_reset_0 (user_rx_reset_0),
    .rxrecclkout_0 (rxrecclkout_0),


//// RX User Interface Signals
    .rx_mii_d_0 (rx_mii_d_0),
    .rx_mii_c_0 (rx_mii_c_0),


//// RX Control Signals
    .ctl_rx_test_pattern_0 (ctl_rx_test_pattern_0),
    .ctl_rx_test_pattern_enable_0 (ctl_rx_test_pattern_enable_0),
    .ctl_rx_data_pattern_select_0 (ctl_rx_data_pattern_select_0),
    .ctl_rx_prbs31_test_pattern_enable_0 (ctl_rx_prbs31_test_pattern_enable_0),




//// RX Stats Signals
    .stat_rx_block_lock_0 (stat_rx_block_lock_0),
    .stat_rx_framing_err_valid_0 (stat_rx_framing_err_valid_0),
    .stat_rx_framing_err_0 (stat_rx_framing_err_0),
    .stat_rx_hi_ber_0 (stat_rx_hi_ber_0),
    .stat_rx_valid_ctrl_code_0 (stat_rx_valid_ctrl_code_0),
    .stat_rx_bad_code_0 (stat_rx_bad_code_0),
    .stat_rx_bad_code_valid_0 (stat_rx_bad_code_valid_0),
    .stat_rx_error_valid_0 (stat_rx_error_valid_0),
    .stat_rx_error_0 (stat_rx_error_0),
    .stat_rx_fifo_error_0 (stat_rx_fifo_error_0),
    .stat_rx_local_fault_0 (stat_rx_local_fault_0),
   .stat_rx_status_0 (stat_rx_status_0),

  .tx_reset_0 (tx_reset_0),
  .user_tx_reset_0 (user_tx_reset_0),
//// TX User Interface Signals
    .tx_mii_d_0 (tx_mii_d_0),
    .tx_mii_c_0 (tx_mii_c_0),

//// TX Control Signals
    .ctl_tx_test_pattern_0 (ctl_tx_test_pattern_0),
    .ctl_tx_test_pattern_enable_0 (ctl_tx_test_pattern_enable_0),
    .ctl_tx_test_pattern_select_0 (ctl_tx_test_pattern_select_0),
    .ctl_tx_data_pattern_select_0 (ctl_tx_data_pattern_select_0),
    .ctl_tx_test_pattern_seed_a_0 (ctl_tx_test_pattern_seed_a_0),
    .ctl_tx_test_pattern_seed_b_0 (ctl_tx_test_pattern_seed_b_0),
    .ctl_tx_prbs31_test_pattern_enable_0 (ctl_tx_prbs31_test_pattern_enable_0),


//// TX Stats Signals
    .stat_tx_local_fault_0 (stat_tx_local_fault_0),



    .gtwiz_reset_tx_datapath_0 (gtwiz_reset_tx_datapath_0),
    .gtwiz_reset_rx_datapath_0 (gtwiz_reset_rx_datapath_0),
    .gtpowergood_out_0 (gtpowergood_out_0),
    .txoutclksel_in_0 (txoutclksel_in_0),
    .rxoutclksel_in_0 (rxoutclksel_in_0),
    .qpllreset_in_0 (qpllreset_in_0),
    .gt_refclk_p (gt_refclk_p),
    .gt_refclk_n (gt_refclk_n),
    .gt_refclk_out (gt_refclk_out),
    .sys_reset (sys_reset),
    .dclk (dclk)
);





pcs64_pkt_gen_mon #(
.PKT_NUM (PKT_NUM))i_pcs64_pkt_gen_mon_0
(
  .gen_clk (tx_mii_clk_0),
 
  .mon_clk (rx_core_clk_0),
  .dclk (dclk),
  .sys_reset (sys_reset),
  .restart_tx_rx (restart_tx_rx_0),
  .send_continuous_pkts (send_continous_pkts_0),
//// User Interface signals
  .completion_status (completion_status_0),
  
//// RX Signals
  .rx_reset(rx_reset_0),
  
  .user_rx_reset(user_rx_reset_0),

  .rx_mii_d (rx_mii_d_0),
  .rx_mii_c (rx_mii_c_0),


//// RX Control Signals
  .ctl_rx_test_pattern (ctl_rx_test_pattern_0),
  .ctl_rx_test_pattern_enable (ctl_rx_test_pattern_enable_0),
  .ctl_rx_data_pattern_select (ctl_rx_data_pattern_select_0),
  .ctl_rx_prbs31_test_pattern_enable (ctl_rx_prbs31_test_pattern_enable_0),


//// RX Stats Signals
  .stat_rx_block_lock (stat_rx_block_lock_0),
  .stat_rx_framing_err_valid (stat_rx_framing_err_valid_0),
  .stat_rx_framing_err (stat_rx_framing_err_0),
  .stat_rx_hi_ber (stat_rx_hi_ber_0),
  .stat_rx_valid_ctrl_code (stat_rx_valid_ctrl_code_0),
  .stat_rx_bad_code (stat_rx_bad_code_0),
  .stat_rx_bad_code_valid (stat_rx_bad_code_valid_0),
  .stat_rx_error_valid (stat_rx_error_valid_0),
  .stat_rx_error (stat_rx_error_0),
  .stat_rx_fifo_error (stat_rx_fifo_error_0),
  .stat_rx_local_fault (stat_rx_local_fault_0),


  .tx_reset(tx_reset_0),
  
  .user_tx_reset (user_tx_reset_0),

//// TX AXIS Signals
  .tx_mii_d (tx_mii_d_0),
  .tx_mii_c (tx_mii_c_0),
//// TX Control Signals
  .ctl_tx_test_pattern (ctl_tx_test_pattern_0),
  .ctl_tx_test_pattern_enable (ctl_tx_test_pattern_enable_0),
  .ctl_tx_test_pattern_select (ctl_tx_test_pattern_select_0),
  .ctl_tx_data_pattern_select (ctl_tx_data_pattern_select_0),
  .ctl_tx_test_pattern_seed_a (ctl_tx_test_pattern_seed_a_0),
  .ctl_tx_test_pattern_seed_b (ctl_tx_test_pattern_seed_b_0),
  .ctl_tx_prbs31_test_pattern_enable (ctl_tx_prbs31_test_pattern_enable_0),


//// TX Stats Signals
  .stat_tx_local_fault (stat_tx_local_fault_0),

   
  .rx_gt_locked_led (rx_gt_locked_led_0),
  .rx_block_lock_led (block_lock_led_0)

    );



assign completion_status = completion_status_0;

endmodule






