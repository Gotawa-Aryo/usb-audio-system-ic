###############################################################################
# Created by write_sdc
###############################################################################
current_design ic_top_usb_audio
###############################################################################
# Timing Constraints
###############################################################################
create_clock -name __VIRTUAL_CLK__ -period 15.0000 
set_clock_uncertainty 0.2500 __VIRTUAL_CLK__
set_input_delay 3.0000 -clock [get_clocks {__VIRTUAL_CLK__}] -add_delay [get_ports {RESET_N}]
set_input_delay 3.0000 -clock [get_clocks {__VIRTUAL_CLK__}] -add_delay [get_ports {SYS_CLK_60M}]
set_input_delay 3.0000 -clock [get_clocks {__VIRTUAL_CLK__}] -add_delay [get_ports {USB_DN}]
set_input_delay 3.0000 -clock [get_clocks {__VIRTUAL_CLK__}] -add_delay [get_ports {USB_DP}]
set_output_delay 3.0000 -clock [get_clocks {__VIRTUAL_CLK__}] -add_delay [get_ports {DAC_MOD_OUT_L}]
set_output_delay 3.0000 -clock [get_clocks {__VIRTUAL_CLK__}] -add_delay [get_ports {USB_DN}]
set_output_delay 3.0000 -clock [get_clocks {__VIRTUAL_CLK__}] -add_delay [get_ports {USB_DP}]
set_output_delay 3.0000 -clock [get_clocks {__VIRTUAL_CLK__}] -add_delay [get_ports {USB_DP_PULL}]
###############################################################################
# Environment
###############################################################################
set_load -pin_load 0.0729 [get_ports {DAC_MOD_OUT_L}]
set_load -pin_load 0.0729 [get_ports {USB_DN}]
set_load -pin_load 0.0729 [get_ports {USB_DP}]
set_load -pin_load 0.0729 [get_ports {USB_DP_PULL}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__inv_1 -pin {ZN} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {RESET_N}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__inv_1 -pin {ZN} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {SYS_CLK_60M}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__inv_1 -pin {ZN} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {USB_DN}]
set_driving_cell -lib_cell gf180mcu_fd_sc_mcu7t5v0__inv_1 -pin {ZN} -input_transition_rise 0.0000 -input_transition_fall 0.0000 [get_ports {USB_DP}]
###############################################################################
# Design Rules
###############################################################################
set_max_transition 3.0000 [current_design]
set_max_capacitance 0.2000 [current_design]
set_max_fanout 10.0000 [current_design]
