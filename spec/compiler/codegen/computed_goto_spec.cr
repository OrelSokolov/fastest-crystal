require "../../spec_helper"

describe "Codegen: computed goto" do
  it "compiles a @[ComputedGoto] endless dispatch chain to an LLVM switch" do
    mod = codegen(<<-CRYSTAL)
      @[ComputedGoto]
      def run(op : Int32) : Int32
        r = 0
        while true
          if op == 0
            r &+= 1
          elsif op == 1
            r &+= 2
          elsif op == 2
            r &+= 3
          else
            r &+= 5
          end
          break
        end
        r
      end

      run(1)
      CRYSTAL

    mod.to_s.should contain("switch")
  end

  it "leaves non-annotated dispatch chains unchanged" do
    mod = codegen(<<-CRYSTAL)
      def run(op : Int32) : Int32
        r = 0
        while true
          if op == 0
            r &+= 1
          elsif op == 1
            r &+= 2
          elsif op == 2
            r &+= 3
          else
            r &+= 5
          end
          break
        end
        r
      end

      run(1)
      CRYSTAL

    mod.to_s.should_not contain("switch")
  end

  it "keeps dispatcher semantics (hand-written chain, full prelude)" do
    run(<<-CRYSTAL, Int32).should eq(9)
      @[ComputedGoto]
      def run3(op : Int32, n : Int32) : Int32
        r = 0
        i = 0
        while true
          if op == 0
            r &+= 1
            op = 1
          elsif op == 1
            r &+= 3
            op = 2
          elsif op == 2
            r &+= 5
            op = 0
          else
            op = 0
          end
          i &+= 1
          break if i >= n
        end
        r
      end

      run3(0, 3)
      CRYSTAL
  end
end
