require "../../spec_helper"

describe "Codegen: fun" do
  it "sets external linkage by default" do
    mod = codegen(<<-CRYSTAL, inject_primitives: false, single_module: false)
    fun foo; end
    fun __crystal_foo; end
    CRYSTAL
    mod.functions["foo"].linkage.should eq(LLVM::Linkage::External)
    mod.functions["__crystal_foo"].linkage.should eq(LLVM::Linkage::External)
  end

  it "sets internal linkage to __crystal_ funs when compiling to single module" do
    mod = codegen(<<-CRYSTAL, inject_primitives: false, single_module: true)
    fun foo; end
    fun __crystal_foo; end
    CRYSTAL
    mod.functions["foo"].linkage.should eq(LLVM::Linkage::External)
    mod.functions["__crystal_foo"].linkage.should eq(LLVM::Linkage::Internal)
  end

  it "defines same fun 3 or more times (#15523)" do
    run(<<-CRYSTAL, Int32).should eq(3)
      fun foo : Int32
        1
      end

      fun foo : Int32
        2
      end

      fun foo : Int32
        3
      end

      foo
      CRYSTAL
  end

  it "returns void from `__crystal_main` in non-evaluated code" do
    mod = codegen(<<-CRYSTAL, inject_primitives: false)
      struct Foo
        @x = 1
        @y = ""
        @z = ""
        @w = ""
      end

      Foo.new
      CRYSTAL

    mod.to_s.should contain("define void @__crystal_main")
  end

  it "sets noalias attribute from @[NoAlias] on lib fun pointer args" do
    mod = codegen(<<-CRYSTAL)
      lib Lib
        fun my_copy = "my_copy"(@[NoAlias] dst : UInt8*, @[NoAlias] src : UInt8*, len : UInt64) : Void
      end

      Lib.my_copy(Pointer(UInt8).new(0_u64), Pointer(UInt8).new(0_u64), 0_u64)
      CRYSTAL

    func = mod.functions["my_copy"]
    func.attributes(LLVM::AttributeIndex.new(1)).no_alias?.should be_true
    func.attributes(LLVM::AttributeIndex.new(2)).no_alias?.should be_true
    func.attributes(LLVM::AttributeIndex.new(3)).no_alias?.should be_false
  end

  it "sets noalias attribute from @[NoAlias] on def pointer args" do
    mod = codegen(<<-CRYSTAL)
      def copy(@[NoAlias] dst : UInt8*, @[NoAlias] src : UInt8*, len : UInt64)
        len
      end

      copy(Pointer(UInt8).new(0_u64), Pointer(UInt8).new(0_u64), 0_u64)
      CRYSTAL

    func = nil
      mod.functions.each do |cand|
        func = cand if cand.name.starts_with?("*copy<")
      end
      func = func.not_nil!
    func.attributes(LLVM::AttributeIndex.new(1)).no_alias?.should be_true
    func.attributes(LLVM::AttributeIndex.new(2)).no_alias?.should be_true
    func.attributes(LLVM::AttributeIndex.new(3)).no_alias?.should be_false
  end

  it "errors when @[NoAlias] is applied to a non-pointer argument" do
    expect_raises(TypeException, "@[NoAlias] can only be applied to pointer arguments") do
      codegen(<<-CRYSTAL)
        def foo(@[NoAlias] x : Int32)
          x
        end

        foo(1)
        CRYSTAL
    end
  end
end
