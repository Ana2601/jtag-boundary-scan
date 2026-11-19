RTL   := rtl/jtag_tap.sv rtl/jtag_bscan.sv
BUILD := build

.PHONY: test lint synth clean

test:
	@mkdir -p $(BUILD)
	iverilog -g2012 -o $(BUILD)/tb.vvp $(RTL) tb/tb_jtag.sv
	vvp -n $(BUILD)/tb.vvp

lint:
	verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL --top-module jtag_bscan $(RTL)

synth:
	@mkdir -p $(BUILD)
	yosys -q -p "read_verilog -sv $(RTL); synth -top jtag_bscan; tee -o $(BUILD)/synth_stat.txt stat"

clean:
	rm -rf $(BUILD)
