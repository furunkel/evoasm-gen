require 'erubis'
require 'evoasm/gen/strio'
require 'evoasm/gen/c_unit'
require 'evoasm/gen/x64'

module Evoasm
  module Gen

    class CTranslator
      include NameUtil

      attr_reader :unit

      OUTPUT_FORMATS = %i(c h ruby_ffi)

      def self.target_filenames(arch, file_type)
        case arch
        when :x64
          case file_type
          when :c
            %w(evoasm-x64-insts.c evoasm-x64-misc.c)
          when :h
            %w(evoasm-x64-insts.h evoasm-x64-enums.h evoasm-x64-misc.h)
          when :ruby_ffi
            %w(x64_enums.rb)
          else
            raise "invalid file type #{file_type}"
          end
        else
          raise "invalid architecture #{arch}"
        end
      end

      def self.templates_dir
        File.join Evoasm::Gen.data_dir, 'templates'
      end

      def self.template_path(filename)
        File.join templates_dir, "#{filename}.erb"
      end

      def self.template_paths(arch, output_type)
        target_filenames(arch, output_type).map do |target_filename|
          File.join templates_dir, "#{target_filename}.erb"
        end
      end

      def initialize(unit)
        @unit = unit
      end

      def translate!(&block)
        render_templates(:c, binding, &block)
        render_templates(:h, binding, &block)
        render_templates(:ruby_ffi, binding, &block)
      end

      def arch
        unit.arch
      end

      private

      def render_templates(file_type, binding, &block)
        target_filenames = self.class.target_filenames(arch, file_type)

        target_filenames.each do |target_filename|
          template_path = self.class.template_path(target_filename)
          renderer = Erubis::Eruby.new(File.read(template_path))
          block[target_filename, renderer.result(binding), file_type]
        end
      end

      def translate_x64_c(&block)
        # NOTE: keep in correct order
        #inst_funcs = inst_funcs_to_c
        #pref_funcs = pref_funcs_to_c
        #permutation_tables = permutation_tables_to_c
        #called_funcs = called_funcs_to_c
        #insts_c = insts_to_c
        #inst_operands = inst_operands_to_c
        #inst_mnems = inst_mnems_to_c
        #inst_params = inst_params_to_c
        #inst_params_type_decl = inst_params_type_decl_to_c
        #inst_params_set_func = inst_params_set_func_to_c
        #param_domains = param_domains_to_c

        #render_templates(:c, binding, &block)
      end

      def inst_funcs_to_c(io = StrIO.new)
        @inst_translators = insts.map do |inst|
          inst_translator = StateMachineCTranslator.new arch, self
          inst_translator.emit_inst_func io, inst

          inst_translator
        end
        io.string
      end

      def bit_mask_to_c(mask)
        name =
          case mask
          when Range then
            "#{mask.min}_#{mask.max}"
          else
            mask.to_s
          end
        const_name_to_c name, arch_prefix(:bit_mask)
      end

      def permutation_tables_to_c
        io = StrIO.new
        @permutation_tables.each do |permutation_table|
          io.puts permutation_table
        end

        Hash(@permutation_tables).each do |n, perms|
        end

        io.string
      end

      def called_funcs_to_c(io = StrIO.new)
        @called_funcs.each do |func, (id, translators)|
          func_translator = StateMachineCTranslator.new arch, self
          func_translator.emit_called_func io, func, id

          translators.each do |translator|
            translator.merge_params func_translator.parameters
          end
        end

        io.string
      end

      def inst_to_c(io, inst, params)
        io.puts '{'
        io.indent do
          io.puts inst.operands.size, eol: ','
          io.puts inst_name_to_c(inst), eol: ','
          io.puts params.size, eol: ','
          io.puts exceptions_bitmap(inst), eol: ','
          io.puts inst_flags_to_c(inst), eol: ','
          io.puts "#{features_bitmap(inst)}ull", eol: ','

          if params.empty?
            io.puts 'NULL,'
          else
            io.puts "(#{inst_param_c_type} *)" + inst_params_var_name(inst), eol: ','
          end
          io.puts '(evoasm_x64_inst_enc_func_t)' + inst_enc_func_name(inst), eol: ','

          if inst.operands.empty?
            io.puts 'NULL,'
          else
            io.puts "(#{operand_c_type} *)#{inst_operands_var_name inst}", eol: ','
          end

          io.puts "(char *) #{inst_mnem_var_name(inst)}"
        end
        io.puts '},'
      end

      def insts_to_c(io = StrIO.new)
        io.puts "static const evoasm_x64_inst_t #{static_insts_var_name}[] = {"
        @inst_translators.each do |translator|
          inst_to_c io, translator.inst, translator.parameters
        end
        io.puts '};'
        io.puts "const evoasm_x64_inst_t *#{insts_var_name} = #{static_insts_var_name};"

        io.string
      end

      def inst_param_to_c(io, inst, params, param_domains)
        return if params.empty?
        io.puts "static const #{inst_param_c_type} #{inst_params_var_name inst}[] = {"
        io.indent do
          params.each do |param|
            param_domain = param_domains[param] || inst.param_domain(param)
            register_param_domain param_domain

            io.puts '{'
            io.indent do
              io.puts inst_param_name_to_c(param), eol: ','
              io.puts '(evoasm_domain_t *) &' + param_domain_var_name(param_domain)
            end
            io.puts '},'
          end
        end
        io.puts '};'
        io.puts
      end

      def inst_params_to_c(io = StrIO.new)
        @inst_translators.each do |translator|
          inst_param_to_c io, translator.inst, translator.parameters, translator.param_domains
        end

        io.string
      end

      def inst_params_type_decl_to_c(io = StrIO.new)
        io.puts 'typedef struct {'
        io.indent do
          params = param_names.symbols.select { |key| !param_names.alias? key }.flat_map do |param_name|
            field_name = inst_param_to_c_field_name param_name
            [
              [field_name, param_c_bitsize(param_name)],
              ["#{field_name}_set", 1],
            ]
          end.sort_by { |n, s| [s, n]}

          params.each do |param, size|
            io.puts "uint64_t #{param} : #{size};"
          end

          p params.inject(0) {|acc, (n, s)| acc + s }./(64.0)
        end

        io.puts '} evoasm_x64_inst_params_t;'
        io.string
      end

      def param_c_bitsize(param_name)
        case param_name
        when :rex_b, :rex_r, :rex_x, :rex_w,
          :vex_l, :force_rex?, :lock?, :force_sib?,
          :force_disp32?, :force_long_vex?, :reg0_high_byte?,
          :reg1_high_byte?
          1
        when :addr_size
          @address_sizes.bitsize
        when :disp_size
          @displacement_sizes.bitsize
        when :scale
          2
        when :modrm_reg
          3
        when :vex_v
          4
        when :reg_base, :reg_index, :reg0, :reg1, :reg2, :reg3, :reg4
          @reg_names.bitsize
        when :imm
          64
        when :moffs, :rel
          64
        when :disp
          32
        when :legacy_pref_order
          3
        else
          raise "missing C type for param #{param_name}"
        end
      end

      def max_params_per_inst
        @instructions.map do |translator|
          translator.parameters.size
        end.max
      end

      def param_idx_bitsize
        Math.log2(max_params_per_inst + 1).ceil.to_i
      end

      def inst_operand_to_c(translator, op, io = StrIO.new, eol:)
        io.puts '{'
        io.indent do
          io.puts op.access.include?(:r) ? '1' : '0', eol: ','
          io.puts op.access.include?(:w) ? '1' : '0', eol: ','
          io.puts op.access.include?(:u) ? '1' : '0', eol: ','
          io.puts op.access.include?(:c) ? '1' : '0', eol: ','
          io.puts op.implicit? ? '1' : '0', eol: ','
          io.puts op.mnem? ? '1' : '0', eol: ','

          params = translator.parameters.reject { |p| State.local_variable_name? p }
          if op.param
            param_idx = params.index(op.param) or \
              raise "param #{op.param} not found in #{params.inspect}" \
                      " (#{translator.inst.mnem}/#{translator.inst.index})"

            io.puts param_idx, eol: ','
          else
            io.puts params.size, eol: ','
          end

          io.puts operand_type_to_c(op.type), eol: ','

          if op.size1
            io.puts operand_size_to_c(op.size1), eol: ','
          else
            io.puts 'EVOASM_X64_N_OPERAND_SIZES', eol: ','
          end

          if op.size2
            io.puts operand_size_to_c(op.size2), eol: ','
          else
            io.puts 'EVOASM_X64_N_OPERAND_SIZES', eol: ','
          end

          if op.reg_type
            io.puts reg_type_to_c(op.reg_type), eol: ','
          else
            io.puts reg_types.n_symbol_to_c, eol: ','
          end

          if op.accessed_bits.key? :w
            io.puts bit_mask_to_c(op.accessed_bits[:w]), eol: ','
          else
            io.puts bit_masks.all_symbol_to_c, eol: ','
          end

          io.puts '{'
          io.indent do
            case op.type
            when :reg, :rm
              if op.reg
                io.puts register_name_to_c(op.reg), eol: ','
              else
                io.puts reg_names.n_symbol_to_c, eol: ','
              end
            when :imm
              if op.imm
                io.puts op.imm, eol: ','
              else
                io.puts 255, eol: ','
              end
            else
              io.puts '255'
            end
          end
          io.puts '}'
        end
        io.puts '}', eol: eol
      end

      def inst_operands_to_c(io = StrIO.new)
        @inst_translators.each do |translator|
          next if translator.inst.operands.empty?
          io.puts "static const #{operand_c_type} #{inst_operands_var_name translator.inst}[] = {"
          io.indent do
            translator.inst.operands.each do |op|
              inst_operand_to_c(translator, op, io, eol: ',')
            end
          end
          io.puts '};'
          io.puts
        end

        io.string
      end

      def inst_mnems_to_c(io = StrIO.new)
        @inst_translators.each do |translator|
          io.puts %Q{static const char #{inst_mnem_var_name translator.inst}[] = "#{translator.inst.mnem}";}
        end

        io.string
      end

      ENUM_MAX_LENGTH = 32

      def param_domain_to_c(io, domain)
        domain_c =
          case domain
          when /int(\d+)/
            type = $1 == '64' ? 'EVOASM_DOMAIN_TYPE_INT64' : 'EVOASM_DOMAIN_TYPE_INTERVAL'
            "{#{type}, #{expr_to_c :"INT#{$1}_MIN"}, #{expr_to_c :"INT#{$1}_MAX"}}"
          when Range
            min_c = expr_to_c domain.begin
            max_c = expr_to_c domain.end
            "{EVOASM_DOMAIN_TYPE_INTERVAL, #{min_c}, #{max_c}}"
          when Array
            if domain.size > ENUM_MAX_LENGTH
              fail 'enum exceeds maximal enum length of'
            end
            values_c = "#{domain.map { |expr| expr_to_c expr }.join ', '}"
            "{EVOASM_DOMAIN_TYPE_ENUM, #{domain.length}, {#{values_c}}}"
          else
            raise
          end

        domain_c_type =
          case domain
          when Range, Symbol
            'evoasm_interval_t'
          when Array
            "evoasm_enum#{domain.size}_t"
          else
            raise
          end
        io.puts "static const #{domain_c_type} #{param_domain_var_name domain} = #{domain_c};"
      end

      def param_domains_to_c(io = StrIO.new)
        registered_param_domains.each do |domain|
          param_domain_to_c io, domain
        end

        io.puts "const uint16_t evoasm_n_domains = #{registered_param_domains.size};"

        io.string
      end

      def request(hash, key, translator)
        id, translators = hash[key]
        if id.nil?
          id = hash.size
          translators = []

          hash[key] = [id, translators]
        end

        translators << translator
        id
      end

      def pref_funcs_to_c(io = StrIO.new)
        @pref_funcs.each do |writes, (id, translators)|
          func_translator = StateMachineCTranslator.new arch, self
          func_translator.emit_pref_func io, writes, id

          translators.each do |translator|
            translator.merge_params func_translator.parameters
          end
        end

        io.string
      end

      def inst_flags_to_c(inst)
        if inst.flags.empty?
          '0'
        else
          inst.flags.map { |flag| inst_flag_to_c flag }
            .join ' | '
        end
      end

      def features_bitmap(inst)
        bitmap(features) do |flag, _|
          inst.features.include?(flag)
        end
      end

      def exceptions_bitmap(inst)
        bitmap(exceptions) do |flag, _|
          inst.exceptions.include?(flag)
        end
      end

      def bitmap(enum, &block)
        enum.symbols.each_with_index.inject(0) do |acc, (flag, index)|
          if block[flag, index]
            acc | (1 << index)
          else
            acc
          end
        end
      end
    end
  end
end