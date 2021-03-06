require 'evoasm/gen/nodes/parameters_type'

module Evoasm
  module Gen
    module Nodes


      class ParametersType

        def to_c(header:)
          io = StringIO.new
          if header
            CParametersTypeDeclaration.new(unit, basic: false).output io
            io.puts
            CParametersTypeDeclaration.new(unit, basic: true).output io
            io.puts
          end

          %i(set get unset type name).each do |type|
            CParametersFunction.new(unit, type, basic: false, stub: !header).output io
            io.puts
            CParametersFunction.new(unit, type, basic: true, stub: !header).output io
          end
          io.puts
          CParametersFunction.new(unit, :to_basic, basic: false, stub: !header).output io

          io.string
        end

        module CParametersTypeUtils
          def parameter_field_name(parameter_name)
            parameter_name.to_s.sub(/\?$/, '')
          end

          def signed_parameter?(parameter_name)
            case parameter_name
            when :disp, :rel, :imm0, :imm1, :moffs
              true
            else
              false
            end
          end

          def field_type(bitsize, signed)
            int_type_size = 64

            if [8, 16, 32].include?(bitsize)
              int_type_size = bitsize
            end

            int_type = "int#{int_type_size}_t"
            unless signed
              int_type.prepend 'u'
            end

            int_type
          end

          def parameter_bitsize(parameter_name, basic)
            case parameter_name
            when :rex_b, :rex_r, :rex_x, :rex_w,
              :vex_l, :force_rex?, :lock?, :force_sib?,
              :force_disp32?, :force_long_vex?, :reg0_high_byte?,
              :reg1_high_byte?
              1
            when :addr_size
              @unit.address_sizes.bitsize
            when :scale
              @unit.scales.bitsize
            when :modrm_reg
              3
            when :vex_v
              4
            when :reg_base, :reg_index, :reg0, :reg1, :reg2, :reg3, :reg4
              @unit.register_ids.bitsize
            when :imm0, :moffs, :rel
              basic ? 32 : 64
            when :imm1
              # Only used for enter
              8
            when :disp
              32
            when :legacy_prefix_order
              3
            else
              raise "missing C type for param #{parameter_name}"
            end
          end

          def parameter_type(parameter_name, basic)
            case parameter_name
            when :force_rex?, :lock?, :force_sib?,
              :force_disp32?, :force_long_vex?, :reg0_high_byte?,
              :reg1_high_byte?
              :bool
            when :rex_b, :rex_r, :rex_x, :rex_w, :vex_l
              :uint1
            when :addr_size
              :addr_size
            when :scale
              :scale
            when :modrm_reg
              :int3
            when :vex_v
              :int4
            when :reg_base, :reg_index, :reg0, :reg1, :reg2, :reg3, :reg4
              :reg
            when :imm0, :moffs, :rel
              basic ? :int32 : :int64
            when :imm1
              # Only used for enter
              :int8
            when :disp
              :int32
            when :legacy_prefix_order
              :int3
            else
              raise "missing C type for param #{parameter_name}"
            end
          end
        end


        class CParametersTypeDeclaration
          include CParametersTypeUtils


          UNIONS = [
            %w(imm imm0 moffs rel),
            %w(imm1 disp)
          ].freeze

          BASIC_UNIONS = [
            %w(imm imm0 moffs rel)
          ].freeze

          def initialize(unit, basic:)
            @unit = unit
            @basic = basic
          end

          def output(io)
            io.puts 'typedef struct {'
            io.indent do
              parameters = @unit.parameter_ids(basic: @basic).symbols
              fields = []
              parameters.each do |parameter_name|
                field_name = parameter_field_name parameter_name

                fields << [field_name, parameter_bitsize(parameter_name, @basic), signed_parameter?(parameter_name)]

                if @unit.undefinedable_parameter? parameter_name, basic: @basic
                  fields << ["#{field_name}_set", 1]
                end
              end

              fields.sort_by do |name, bitsize|
                [bitsize, name]
              end.group_by do |name, _|
                (@basic ? BASIC_UNIONS : UNIONS).index { |union| union.include? name } || name
              end.each_value do |union|
                if union.size > 1
                  io.puts 'evoasm_packed(union {'
                  indent = true
                else
                  indent = false
                end

                io.indent(relative: indent ? 1 : 0) do
                  union.each do |name, bitsize, signed|
                    io.puts "#{field_type bitsize, signed} #{name} : #{bitsize};"
                  end
                end

                if union.size > 1
                  io.puts '});'
                end
              end

              p ['words', fields.inject(0) { |acc, (n, s)| acc + s }./(64.0)]
            end

            io.puts "} #{@unit.c_parameters_type_name @basic};"
            io.string
          end
        end

        class CParametersFunction
          include CParametersTypeUtils

          def initialize(unit, type, basic:, stub:)
            @unit = unit
            @basic = basic
            @type = type
            @stub = stub
          end

          def output(io)
            if @stub
              output_stub io
            else
              output_full io
            end
          end

          private

          def output_stub(io)
            io.block prototype do
              io.write '  '
              io.write 'return ' if %i(get type name to_basic).include? @type
              io.write function_name(false)
              io.write '('
              io.write function_parameter_names.join ', '
              io.puts ');'
            end

          end

          def output_full(io)
            io.block prototype do
              io.block 'switch(param)' do
                parameter_ids = @unit.parameter_ids(basic: @basic)
                parameter_ids.each do |parameter_id, _|
                  switch_case(io, parameter_id)
                end

                io.puts 'default:'
                io.puts '  evoasm_assert_not_reached();'
              end
            end
          end

          def return_type
            case @type
            when :get
              'int64_t'
            when :set, :unset
              'void'
            when :type
              'evoasm_x64_param_type_t'
            when :name
              'const char *'
            when :to_basic
              'evoasm_x64_basic_param_id_t'
            else
              raise
            end
          end

          def function_parameter_type(parameter_name)
            case parameter_name
            when 'params'
              "#{@unit.c_parameters_type_name @basic} *"
            when 'param_val'
              'int64_t'
            when 'param'
              if @basic
                'evoasm_x64_basic_param_id_t'
              else
                'evoasm_x64_param_id_t'
              end
            else
              raise
            end
          end

          def function_parameter_names
            case @type
            when :set
              %w(params param param_val)
            when :get, :unset
              %w(params param)
            when :type, :name, :to_basic
              %w(param)
            else
              raise
            end
          end

          def function_name(stub = @stub)
            function_name = 'evoasm_x64'

            function_name << '_basic' if @basic

            case @type
            when :type, :name, :to_basic
              function_name << '_param'
            else
              function_name << '_params'
            end

            case @type
            when :type, :name
              function_name << '_get'
            end

            function_name << "_#{@type}"
            function_name << '_' unless stub

            function_name
          end

          def parameter_list
            function_parameter_names.map do |parameter_name|
              "#{function_parameter_type parameter_name} #{parameter_name}"
            end.join ', '
          end

          def function_modifiers
            'static inline ' unless @stub
          end

          def prototype(stub = @stub)
            "#{function_modifiers}#{return_type} #{function_name stub}(#{parameter_list})"
          end

          def switch_case(io, parameter_name)
            field_name = parameter_field_name parameter_name
            bitsize = parameter_bitsize(parameter_name, @basic)
            signed = signed_parameter?(parameter_name)
            bitmask = (1 << bitsize) - 1
            undefinedable = @unit.undefinedable_parameter? parameter_name, basic: @basic

            parameter_ids = @unit.parameter_ids basic: @basic
            basic_parameter_ids = @unit.parameter_ids basic: true

            io.puts "case #{parameter_ids.symbol_to_c parameter_name}:"
            case @type
            when :get
              io.puts "  return (#{return_type}) params->#{field_name};"
            when :set
              io.puts "  params->#{field_name} = (#{field_type bitsize, signed}) (((uint64_t) param_val) & 0x#{bitmask.to_s 16});"
              if undefinedable
                io.puts "  params->#{field_name}_set = true;"
              end
              io.puts '  break;'
            when :unset
              io.puts "  params->#{field_name} = 0;"
              if undefinedable
                io.puts "  params->#{field_name}_set = false;"
              end
              io.puts '  break;'
            when :type
              io.puts "  return #{@unit.parameter_types.symbol_to_c parameter_type(parameter_name, @basic)};"
            when :name
              io.puts %Q{  return "#{parameter_name}";}
            when :to_basic
              if basic_parameter_ids.include?(parameter_name)
                io.puts "  return #{basic_parameter_ids.symbol_to_c parameter_name};"
              else
                io.puts "  return #{basic_parameter_ids.symbol_to_c :none};"
              end
            end
          end
        end
      end
    end
  end
end
