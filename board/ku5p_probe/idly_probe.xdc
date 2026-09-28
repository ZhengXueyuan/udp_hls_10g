# idly_probe.xdc - KU5P bank86 RGMII 引脚 (厂商 Demo PCIe.xdc 的实测引脚)
create_clock -period 8.000 -name phy1_rxc [get_ports eth_rxc]
set_property PACKAGE_PIN D11 [get_ports eth_rxc]
set_property PACKAGE_PIN B10 [get_ports eth_rxd0]
set_property PACKAGE_PIN A10 [get_ports eth_rxctl]
set_property PACKAGE_PIN J10 [get_ports eth_txc]
set_property PACKAGE_PIN F9  [get_ports eth_txd0]
set_property PACKAGE_PIN G9  [get_ports eth_txctl]
set_property IOSTANDARD LVCMOS33 [get_ports {eth_rxc eth_rxd0 eth_rxctl eth_txc eth_txd0 eth_txctl}]
