/*  norsniff.v - NOR sniffer for PS3

Copyright (C) 2010-2011  Hector Martin "marcan" <hector@marcansoft.com>

This code is licensed to you under the terms of the GNU GPL, version 2;
see file COPYING or http://www.gnu.org/licenses/old-licenses/gpl-2.0.txt
*/

module usbstreamer (
	input mclk, reset,
	inout [7:0] usb_d, input usb_rxf_n, usb_txe_n, output usb_rd_n, output reg usb_wr_n, output usb_oe_n,
	output have_space, input [7:0] data, input wr
);

	// unused read lines
	assign usb_rd_n = 1;
	assign usb_oe_n = 1;

	// FIFO configuration
	parameter FIFO_THRESHOLD = 8;
	parameter FIFO_LOG_SIZE = 13;
	parameter FIFO_SIZE = 2**FIFO_LOG_SIZE;

	// FIFO and pointers
	reg [7:0] fifo_mem[FIFO_SIZE-1:0];

	reg [FIFO_LOG_SIZE-1:0] fifo_read_ptr;
	reg [FIFO_LOG_SIZE-1:0] fifo_write_ptr;

	wire [FIFO_LOG_SIZE-1:0] fifo_write_ptr_next = fifo_write_ptr + 1;
	wire [FIFO_LOG_SIZE-1:0] fifo_used_space = fifo_write_ptr - fifo_read_ptr;

	wire fifo_empty = fifo_write_ptr == fifo_read_ptr;
	wire fifo_full = fifo_write_ptr_next == fifo_read_ptr;
	assign have_space = fifo_used_space < (FIFO_SIZE - FIFO_THRESHOLD);

	// silly FT2232 handshake handking
	reg just_sent;
	reg pending_byte;

	// data output buffer
	reg [7:0] usb_dout;

	// we're only doing writes so no Z state
	assign usb_d = usb_dout;

	// FIFO write process
	always @(posedge mclk or negedge reset) begin
		if (!reset) begin
			fifo_write_ptr <= 0;
		end else begin
			if (!fifo_full && wr) begin
				fifo_mem[fifo_write_ptr] <= data;
				fifo_write_ptr <= fifo_write_ptr + 1;
			end
		end
	end

	// FIFO read / USB stream process
	always @(posedge mclk or negedge reset) begin
		if (!reset) begin
			fifo_read_ptr <= 0;
			usb_wr_n <= 1;
			just_sent <= 0;
			pending_byte <= 0;
			// note: no reset of usb_dout because it's really a BRAM output port which is only synchronous
		end else begin
			// send a byte if the FT2232 lets us, and we have stuff in the FIFO _or_ a pending byte that it barfed back at us previously
			if ((!fifo_empty || pending_byte) && !usb_txe_n) begin
				// only fetch new byte if we don't have a byte hanging around
				if (!pending_byte) begin
					usb_dout <= fifo_mem[fifo_read_ptr];
					fifo_read_ptr <= fifo_read_ptr + 1;
				end
				usb_wr_n <= 0;
				just_sent <= 1;
				pending_byte <= 0;
			end else begin
				// if we sent a byte and the FT2232 rejected it, hold it
				if (just_sent && usb_txe_n)
					pending_byte <= 1;
				// and keep usb_dout state for next try
				usb_wr_n <= 1;
				just_sent <= 0;
			end
		end
	end
endmodule

module norflash (
	input mclk,
	output [3:0] led,
	inout [7:0] usb_d, input usb_rxf_n, usb_txe_n, output usb_rd_n, usb_wr_n, usb_oe_n,

	inout [22:0] nor_a, inout [15:0] nor_d, inout nor_we_n, inout nor_ce_n, inout nor_oe_n,
	inout nor_reset_n, input nor_ready, input nor_vcc, inout nor_trist_n
);

	reg out_trist = 0;
	assign nor_trist_n = (nor_vcc && out_trist) ? 1'b0 : 1'bZ;

	reg drive = 0;
	wire really_drive = drive && nor_vcc && out_trist;

	reg drive_d = 0;
	wire really_drive_d = really_drive && drive_d && nor_oe_n;

	reg out_we, out_ce, out_oe;
	reg out_reset;
	reg [22:0] out_a;
	reg [15:0] out_d;

	assign nor_a = really_drive ? out_a : 23'hZZZZZZ;
	assign nor_d = really_drive_d ? out_d : 16'hZZZZ;
	assign nor_we_n = really_drive ? !out_we : 1'bZ;
	assign nor_oe_n = really_drive ? !out_oe : 1'bZ;
	assign nor_ce_n = really_drive ? !out_ce : 1'bZ;
	assign nor_reset_n = really_drive ? !out_reset : 1'bZ;

	// FPGA reset generator
	reg reset = 0;
	always @(posedge mclk) begin
		reset <= 1;
	end

	// Blinky LED counter
	reg [23:0] led_div;
	always @(posedge mclk or negedge reset) begin
		if (!reset) begin
			led_div <= 0;
		end else begin
			led_div <= led_div + 24'b1;
		end
	end

	// USB streamer lines
	wire can_write;
	wire [7:0] tx_data;
	reg tx_wr;

	// instantiate USB streamer
	usbstreamer ustm (
		mclk, reset,
		usb_d, usb_rxf_n, usb_txe_n, usb_rd_n, usb_wr_n, usb_oe_n,
		can_write, tx_data, tx_wr
	);

	reg overflow;

	// assign some leds
	assign led[0] = !overflow;
	assign led[1] = !can_write;
	assign led[3] = led_div[23];

	// FIFO configuration
	parameter FIFO_THRESHOLD = 90;
	parameter FIFO_LOG_SIZE = 13;
	parameter FIFO_SIZE = 2**FIFO_LOG_SIZE;

	// FIFO and pointers
	reg [23:0] fifo_mem[FIFO_SIZE-1:0];

	reg [FIFO_LOG_SIZE-1:0] fifo_read_ptr;
	reg [FIFO_LOG_SIZE-1:0] fifo_write_ptr;

	wire [FIFO_LOG_SIZE-1:0] fifo_write_ptr_next = fifo_write_ptr + 1;

	wire fifo_empty = fifo_write_ptr == fifo_read_ptr;
	wire fifo_full = fifo_write_ptr_next == fifo_read_ptr;

	reg [1:0] fifo_sub;

	reg [23:0] rbuf;

	assign tx_data = fifo_sub == 1 ? rbuf[23:16] :
					(fifo_sub == 2 ? rbuf[15:8] : rbuf[7:0]);

	// FIFO read process
	always @(posedge mclk or negedge reset) begin
		if (!reset) begin
			fifo_read_ptr <= 0;
			fifo_sub <= 0;
		end else begin
			tx_wr <= 0;
			if (can_write && !fifo_empty) begin
				tx_wr <= 1;
				if (fifo_sub == 0)
					rbuf <= fifo_mem[fifo_read_ptr];
				if (fifo_sub == 2) begin
					fifo_read_ptr <= fifo_read_ptr + 1;
					fifo_sub <= 0;
				end else
					fifo_sub <= fifo_sub + 1;
			end
		end
	end

	reg [22:0] buf_addr1;
	reg [22:0] buf_addr2;
	reg [22:0] last_addr;

	reg tog;
	reg pend;
	assign led[2] = tog;

	// sniffer process
	always @(posedge mclk or negedge reset) begin
		if (!reset) begin
			tog <= 0;
			fifo_write_ptr <= 0;
			last_addr <= 0;
			buf_addr1 <= 0;
			buf_addr2 <= 0;
			pend <= 0;
			overflow <= 0;
		end else begin
			buf_addr1 <= nor_a;
			buf_addr2 <= buf_addr1;
			if (last_addr != buf_addr2) begin
				if (pend) begin
					last_addr <= buf_addr2;
					tog <= !tog;
					if (fifo_full) begin
						overflow <= 1;
					end else begin
						fifo_mem[fifo_write_ptr] <= buf_addr2;
						fifo_write_ptr <= fifo_write_ptr_next;
					end
				end else
					pend <= 1;
			end else
				pend <= 0;
		end
	end

endmodule
