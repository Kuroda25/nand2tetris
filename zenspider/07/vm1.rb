#!/usr/bin/env ruby -w

class String
  def number_instructions
    i = -1
    self.lines.map { |s|
      if s =~ /^\// then
        "\n#{s}"
      else
        i += 1
        "%-21s // %d" % [s.chomp, i]
      end
    }.join "\n"
  end
end

class Compiler
  def self.run paths
    paths.each do |path|
      File.open path do |file|
        puts postprocess Compiler.new.assemble file
      end
    end
  end

  def self.postprocess result
    result.flatten.compact.join("\n").gsub(/^(?!\/)/, '   ').number_instructions
  end

  SEGMENTS = %w(argument local static constant this that pointer temp).join "|"
  OPS      = %w(add sub neg eq gt lt and or not).join "|"

  def assemble io
    io.each_line.map { |line|
      case line.strip.sub(%r%\s*//.*%, '')
      when "" then
        nil
      when /^push (#{SEGMENTS}) (\d+)/ then
        Push.new $1, $2.to_i
      when /^pop (#{SEGMENTS}) (\d+)/ then
        Pop.new $1, $2.to_i
      when /^(#{OPS})$/ then
        Op.new $1
      else
        raise "Unparsed: #{line.inspect}"
      end
    }
  end

  module Asmable
    def asm *instructions
      instructions
    end

    def assemble(*instructions)
      instructions.flatten.compact.join "\n"
    end
  end

  module Stackable
    @@next_num = Hash.new 0

    def next_num name
      n = @@next_num[name] += 1
      "#{name}.#{n}"
    end

    def push_d deref = "AM=M+1"
      # deref_sp      dec_ptr  write
      asm "@SP", deref, "A=A-1", "M=D"
    end

    def peek
      asm "@SP", "AM=M-1", "D=M"
    end
  end

  module Operable
    def pop dest
      asm "@SP", "AM=M-1", "#{dest}=M"
    end

    def binary *instructions
      asm pop(:D), "A=A-1", "A=M", instructions
    end

    def unary *instructions
      asm "@SP", "A=M-1", *instructions
    end

    def binary_test test
      addr = next_num test
      binary("D=A-D",
             "@#{addr}",
             "D;#{test}",
             "D=0",
             "@#{addr}.done",
             "0;JMP",
             "(#{addr})",
             "D=-1",
             "(#{addr}.done)")
    end

    def neg; unary "M=-M";      end
    def not; unary "M=!M";      end

    def add; binary "D=A+D";    end
    def and; binary "D=A&D";    end
    def or;  binary "D=A|D";    end
    def sub; binary "D=A-D";    end

    def eq;  binary_test "JEQ"; end
    def gt;  binary_test "JGT"; end
    def lt;  binary_test "JLT"; end
  end

  module Segmentable
    def name
      self.class.name.split(/::/).last.downcase
    end

    def dereference name
      case offset
      when 0 then
        asm "@#{name}", "A=M"
      when 1 then
        asm "@#{name}", "A=M+1"
      else
        asm "@#{name}", "D=M", "@#{offset}", "A=A+D"
      end
    end

    def constant
      asm "@#{offset}"
    end

    def local
      dereference "LCL"
    end

    def argument
      dereference "ARG"
    end

    def this
      dereference "THIS"
    end

    def that
      dereference "THAT"
    end

    def temp
      asm "@R#{offset + 5}"
    end

    def static
      off = [ "@#{offset}", "A=A+D" ] if offset
      asm "@16", "D=A", off
    end

    def pointer
      off = "A=A+1" if offset != 0
      asm "@THIS", off
    end
  end

  class StackThingy < Struct.new :segment, :offset
    include Asmable
    include Stackable
    include Segmentable

    def comment
      asm "// #{name} #{segment} #{offset}"
    end
  end

  class Push < StackThingy
    def store
      asm segment == "constant" ? "D=A" : "D=M"
    end

    def to_s
      assemble(comment,
               send(segment),
               store,
               push_d)
    end
  end

  class Pop < StackThingy
    def temp_store reg
      asm reg, "M=D", yield, reg, "A=M"
    end

    def store
      asm "D=A"
    end

    def to_s
      assemble(comment,
               send(segment),
               store,
               temp_store("@R15") do
                 peek
               end,
               asm("M=D"))
    end
  end

  class Op < Struct.new :msg
    include Asmable
    include Stackable
    include Operable

    def comment
      asm "// #{msg}"
    end

    def push_d
      super "A=M" unless %w[not neg].include? msg
    end

    def to_s
      assemble(comment,
               send(msg), # perform whatever operation, put into D
               push_d)
    end
  end
end

Compiler.run ARGV if $0 == __FILE__
