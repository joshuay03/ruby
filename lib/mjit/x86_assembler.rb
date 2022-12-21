# frozen_string_literal: true
# https://www.intel.com/content/dam/develop/public/us/en/documents/325383-sdm-vol-2abcd.pdf
module RubyVM::MJIT
  class X86Assembler
    ByteWriter = CType::Immediate.parse('char')

    ### prefix ###
    # REX =   0100WR0B
    REX_W = 0b01001000

    def initialize
      @bytes = []
    end

    def compile(addr)
      writer = ByteWriter.new(addr)
      # If you pack bytes containing \x00, Ruby fails to recognize bytes after \x00.
      # So writing byte by byte to avoid hitting that situation.
      @bytes.each_with_index do |byte, index|
        writer[index] = byte
      end
      @bytes.size
    ensure
      @bytes.clear
    end

    def add(dst, src)
      case [dst, src]
      # ADD r/m64, imm8
      in [Symbol => dst_reg, Integer => src_imm] if r_reg?(dst_reg) && src_imm <= 0xff
        # REX.W + 83 /0 ib
        # MI: Operand 1: ModRM:r/m (r, w), Operand 2: imm8/16/32
        insn(
          prefix: REX_W,
          opcode: 0x83,
          mod_rm: mod_rm(mod: 0b11, rm: reg_code(dst_reg)),
          imm: imm8(src_imm),
        )
      else
        raise NotImplementedError, "add: not-implemented input: #{dst.inspect}, #{src.inspect}"
      end
    end

    def mov(dst, src)
      case [dst, src]
      # MOV r/m64, imm32 (Mod 00)
      in [[Symbol => dst_reg], Integer => src_imm] if r_reg?(dst_reg)
        # REX.W + C7 /0 id
        # MI: Operand 1: ModRM:r/m (w), Operand 2: imm8/16/32/64
        insn(
          prefix: REX_W,
          opcode: 0xc7,
          mod_rm: mod_rm(mod: 0b00, rm: reg_code(dst_reg)), # Mod 00: [reg]
          imm: imm32(src_imm),
        )
      # MOV r/m64, imm32 (Mod 11)
      in [Symbol => dst_reg, Integer => src_imm] if r_reg?(dst_reg)
        # REX.W + C7 /0 id
        # MI: Operand 1: ModRM:r/m (w), Operand 2: imm8/16/32/64
        insn(
          prefix: REX_W,
          opcode: 0xc7,
          mod_rm: mod_rm(mod: 0b11, rm: reg_code(dst_reg)), # Mod 11: reg
          imm: imm32(src_imm),
        )
      # MOV r/m64, r64
      in [[Symbol => dst_reg, Integer => dst_offset], Symbol => src_reg] if r_reg?(dst_reg) && r_reg?(src_reg) && dst_offset <= 0xff
        # REX.W + 89 /r
        # MR: Operand 1: ModRM:r/m (w), Operand 2: ModRM:reg (r)
        insn(
          prefix: REX_W,
          opcode: 0x89,
          mod_rm: mod_rm(mod: 0b01, reg: reg_code(src_reg), rm: reg_code(dst_reg)), # Mod 01: [reg]+disp8
          disp: dst_offset,
        )
      # MOV r64, r/m64 (Mod 00)
      in [Symbol => dst_reg, [Symbol => src_reg]] if r_reg?(dst_reg) && r_reg?(src_reg)
        # REX.W + 8B /r
        # RM: Operand 1: ModRM:reg (w), Operand 2: ModRM:r/m (r)
        insn(
          prefix: REX_W,
          opcode: 0x8b,
          mod_rm: mod_rm(mod: 0b00, reg: reg_code(dst_reg), rm: reg_code(src_reg)), # Mod 00: [reg]
        )
      # MOV r64, r/m64 (Mod 01)
      in [Symbol => dst_reg, [Symbol => src_reg, Integer => src_offset]] if r_reg?(dst_reg) && r_reg?(src_reg) && src_offset <= 0xff
        # REX.W + 8B /r
        # RM: Operand 1: ModRM:reg (w), Operand 2: ModRM:r/m (r)
        insn(
          prefix: REX_W,
          opcode: 0x8b,
          mod_rm: mod_rm(mod: 0b01, reg: reg_code(dst_reg), rm: reg_code(src_reg)), # Mod 01: [reg]+disp8
          disp: src_offset,
        )
      else
        raise NotImplementedError, "mov: not-implemented input: #{dst.inspect}, #{src.inspect}"
      end
    end

    # RET
    def ret
      # Near return: A return to a procedure within the current code segment
      insn(opcode: 0xc3)
    end

    private

    def insn(prefix: nil, opcode:, mod_rm: nil, disp: nil, imm: nil)
      if prefix
        @bytes.push(prefix)
      end
      @bytes.push(opcode)
      if mod_rm
        @bytes.push(mod_rm)
      end
      if disp
        if disp < 0 || disp > 0xff # TODO: support displacement in 2 or 4 bytes as well
          raise NotImplementedError, "not-implemented disp: #{disp}"
        end
        @bytes.push(disp)
      end
      if imm
        @bytes.push(*imm)
      end
    end

    def reg_code(reg)
      case reg
      when :al, :ax, :eax, :rax then 0
      when :cl, :cx, :ecx, :rcx then 1
      when :dl, :dx, :edx, :rdx then 2
      when :bl, :bx, :ebx, :rbx then 3
      when :ah, :sp, :esp, :rsp then 4
      when :ch, :bp, :ebp, :rbp then 5
      when :dh, :si, :esi, :rsi then 6
      when :bh, :di, :edi, :rdi then 7
      else raise ArgumentError, "unexpected reg: #{reg.inspect}"
      end
    end

    # Table 2-2. 32-Bit Addressing Forms with the ModR/M Byte
    #
    #  7  6  5  4  3  2  1  0
    # +--+--+--+--+--+--+--+--+
    # | Mod | Reg/   | R/M    |
    # |     | Opcode |        |
    # +--+--+--+--+--+--+--+--+
    #
    # The r/m field can specify a register as an operand or it can be combined
    # with the mod field to encode an addressing mode.
    #
    # /0: R/M is 0 (not used)
    # /r: R/M is a register
    def mod_rm(mod:, reg: 0, rm: 0)
      if mod > 0b11
        raise ArgumentError, "too large Mod: #{mod}"
      end
      if reg > 0b111
        raise ArgumentError, "too large Reg/Opcode: #{reg}"
      end
      if rm > 0b111
        raise ArgumentError, "too large R/M: #{rm}"
      end
      (mod << 6) + (reg << 3) + rm
    end

    # ib: 1 byte
    def imm8(imm)
      if imm > 0xff
        raise ArgumentError, "unexpected imm8: #{imm}"
      end
      [imm]
    end

    # id: 4 bytes
    def imm32(imm)
      bytes = []
      bits = imm
      4.times do
        bytes << (bits & 0xff)
        bits >>= 8
      end
      if bits != 0
        raise ArgumentError, "unexpected imm32: #{imm}"
      end
      bytes
    end

    def r_reg?(reg)
      reg.start_with?('r')
    end
  end
end
