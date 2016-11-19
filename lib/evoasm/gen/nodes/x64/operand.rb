require 'evoasm/gen/nodes/x64/instruction'
require 'evoasm/gen/nodes/operand'

module Evoasm
  module Gen
    module Nodes
      module X64
        class Operand < Nodes::Operand

          attr_reader :name, :parameter_name, :type, :size1, :size2, :read, :written,
                      :undefined, :conditionally_written, :register, :imm, :register_type, :register_size,
                      :mem_size, :imm_size, :read_flags, :written_flags

          IMM_OP_REGEXP = /^(imm|rel)(\d+)?$/
          MEM_OP_REGEXP = /^m(\d*)$/
          MOFFS_OP_REGEXP = /^moffs(\d+)$/
          VSIB_OP_REGEXP = /^vm(?:\d+)(x|y)(\d+)$/
          REG_OP_REGEXP = /^(?<reg>xmm|ymm|zmm|mm)(?<range>\[\d+\.\.\d+\])?$|^(?<reg>r)(?<reg_size>8|16|32|64)$/
          RM_OP_REGEXP = %r{^(?:(?<reg>xmm|ymm|zmm|mm)|(?<reg>r)(?<reg_size>8|16|32|64)?)/m(?<mem_size>\d+)$}

          def initialize(unit, operands, name, flags, read_flags, written_flags)
            super(unit)

            self.parent = operands

            @name = name
            @read_flags = read_flags
            @written_flags = written_flags

            @encoded = flags.include? :e
            @mnemonic = flags.include? :m
            @read = flags.include? :r
            @written = flags.include? :w
            @conditionally_written = flags.include? :c

            if name == name.upcase
              initialize_implicit
            else
              initialize_explicit
            end
          end

          def can_encode_register?
            type == :rm || type == :reg
          end

          def flags_type
            case name
            when 'RFLAGS' then
              :rflags
            when 'MXCSR' then
              :mxcsr
            else
              nil
            end
          end

          def encoded?
            @encoded
          end

          def implicit?
            @implicit
          end

          def mnemonic?
            @mnemonic
          end

          alias read? read
          alias written? written
          alias conditionally_written? conditionally_written
          alias undefined? undefined

          def size
            @register_size || @imm_size || @mem_size
          end

          def size1
            @register_size || @imm_size || @index_register_size
          end

          def size2
            @mem_size
          end

          def word_type1
            @register_word_type || size_to_word_type(size1)
          end

          def word_type2
            size_to_word_type(size2)
          end

          def access
            access = []
            access << :r if read?
            access << :w if written?
            access << :c if conditionally_written?

            access
          end

          private

          def size_to_word_type(size)
            case size
            when 8
              :lb
            when 16
              :w
            when 32
              :dw
            when 64
              :lqw
            when 128
              :dqw
            when 256, 512
              :vw
            else
              raise "unknown operand size #{size}"
            end
          end

          def initialize_explicit
            case name
            when IMM_OP_REGEXP
              @type = :imm
              @imm_size = $2 && $2.to_i

              if $1 == 'imm'
                @parameter_name = :"imm#{parent.next_imm_index}"
              else
                @parameter_name = $1.to_sym
              end
            when RM_OP_REGEXP
              @type = :rm
              mem_size = Integer($~[:mem_size])
              reg_size =
                if $~[:reg_size].nil? || $~[:reg_size].empty?
                  mem_size
                else
                  Integer($~[:reg_size])
                end
              initialize_reg $~[:reg], reg_size, mem_size
            when REG_OP_REGEXP
              @type = :reg
              initialize_reg $~[:reg], $~[:reg_size].to_i
            when MEM_OP_REGEXP
              @type = :mem
              @mem_size = $1.empty? ? nil : $1.to_i
            when MOFFS_OP_REGEXP
              @type = :mem
              @mem_size = Integer($1)
              @parameter_name = :moffs
            when VSIB_OP_REGEXP
              @type = :vsib
              @mem_size = $2.to_i
              @index_register_size =
                case $1
                when 'x'
                  128
                when 'y'
                  256
                when 'z'
                  512
                end
            else
              raise "unexpected operand '#{name}' (#{instruction.name})"
            end

            if type == :rm || type == :reg
              @parameter_name = :"reg#{parent.next_reg_index}"
            end
          end

          ALLOWED_REG_SIZES = [8, 16, 32, 64].freeze

          def initialize_reg(reg, reg_size, mem_size = nil)
            @register_type, @register_size, @mem_size =
              case reg
              when 'r'
                raise "invalid reg size #{reg_size}" unless ALLOWED_REG_SIZES.include?(reg_size)
                [:gp, reg_size, mem_size]
              when 'xmm'
                [:xmm, 128, mem_size]
              when 'ymm'
                [:xmm, 256, mem_size]
              when 'zmm'
                [:zmm, 512, mem_size]
              when 'mm'
                [:mm, 64, mem_size]
              else
                raise "unexpected reg type '#{reg}/#{reg_size}'"
              end
          end

          def initialize_implicit
            if name =~ /^(\d)$/
              @type = :imm
              @imm = $1
            else
              reg_name = name.gsub(/\[|\]/, '')
              @type = name =~ /^\[/ ? :mem : :reg

              #FIXME: find a way to handle
              # this: memory expressions involving
              # multiple registers e.g. [RBX + AL] in XLAT
              if reg_name =~ /\+/
                reg_name = reg_name.split(/\s*\+\s*/).first
              end

              @register_type = :gp
              @register =
                case reg_name
                when 'RAX', 'EAX', 'AX', 'AL', 'AH'
                  :A
                when 'RCX', 'ECX', 'CX', 'CL'
                  :C
                when 'RDX', 'EDX', 'DX'
                  :D
                when 'RBX', 'EBX'
                  :B
                when 'RSP', 'SP'
                  :SP
                when 'RBP', 'BP'
                  :BP
                when 'RSI', 'ESI', 'SI', 'SIL'
                  :SI
                when 'RDI', 'EDI', 'DI', 'DIL'
                  :DI
                when 'RIP'
                  @register_type = :ip
                  :IP
                when 'XMM0'
                  @register_type = :xmm
                  @register_size = 128
                  :XMM0
                when 'RFLAGS'
                  @register_type = :rflags
                  @register_size = 64
                  :RFLAGS
                when 'MXCSR'
                  @register_type = :mxcsr
                  @register_size = 32
                  :MXCSR
                else
                  raise ArgumentError, "unexpected register '#{reg_name}'"
                end

              @register_size ||=
                case reg_name
                when 'RAX', 'RCX', 'RDX', 'RBX', 'RSP', 'RBP', 'RSI', 'RDI', 'RIP'
                  64
                when 'EAX', 'ECX', 'EDX', 'EBX', 'ESI', 'EDI'
                  32
                when 'AX', 'CX', 'DX', 'SP', 'BP', 'SI', 'DI'
                  16
                when 'CL', 'SIL', 'DIL'
                  8
                when 'AL'
                  @register_word_type = :lb
                  8
                when 'AH'
                  @register_word_type = :hb
                  8
                else
                  raise ArgumentError, "unexpected register '#{reg_name}'"
                end
            end

            @implicit = true
          end
        end
      end
    end
  end
end
