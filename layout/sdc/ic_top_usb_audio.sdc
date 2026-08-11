###############################################################################
# Created by write_sdc
###############################################################################
current_design ic_top_usb_audio
###############################################################################
# Timing Constraints
###############################################################################
create_clock -name __VIRTUAL_CLK__ -period 15.0000 
set_clock_uncertainty 0.2500 __VIRTUAL_CLK__
set_input_delay 3.0000 -clock [get_clocks {__VIRTUAL_CLK__}] -add_delay [get_ports {clk60mhz}]
set_input_delay 3.0000 -clock [get_clocks {__VIRTUAL_CLK__}] -add_delay [get_ports {reset_n}]
set_input_delay 3.0000 -clock [get_clocks {__VIRTUAL_CLK__}] -add_delay [get_ports {usb_dn}]
set_input_delay 3.0000 -clock [get_clocks {__VIRTUAL_CLK__}] -add_delay [get_ports {usb_dp}]
set_output_delay 3.0000 -clock [get_clocks {__VIRTUAL_CLK__}] -add_delay [get_ports {bitstream_out}]
set_output_delay 3.0000 -clock [get_clocks {__VIRTUAL_CLK__}] -add_delay [get_ports {usb_dn}]
set_output_delay 3.0000 -clock [get_clocks {__VIRTUAL_CLK__}] -add_delay [get_ports {usb_dp}]
set_output_delay 3.0000 -clock [get_clocks {__VIRTUAL_CLK__}] -add_delay [get_ports {usb_dp_pull}]
###############################################################################
# Environment
###############################################################################
set_load -pin_load 0.0729 [get_ports {bitstream_out}]
set_load -pin_load 0.0729 [get_ports {usb_dn}]
set_load -pin_load 0.0729 [get_ports {usb_dp}]
set_load -pin_load 0.0729 [get_ports {usb_dp_pull}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__inv_1 -pin {ZN} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {clk60mhz}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__inv_1 -pin {ZN} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {reset_n}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__inv_1 -pin {ZN} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {usb_dn}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__inv_1 -pin {ZN} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {usb_dp}]
###############################################################################
# Design Rules
###############################################################################
set_max_transition 3.0000 [current_design]
set_max_capacitance 0.2000 [current_design]
set_max_fanout 10.0000 [current_design]
