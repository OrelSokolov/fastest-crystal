require "./lib_llvm"
{% if flag?(:win32) %}
  @[Link(ldflags: "#{__DIR__}/ext/llvm_ext.obj")]
{% else %}
  @[Link(ldflags: "#{__DIR__}/ext/llvm_ext.o")]
{% end %}
lib LibLLVMExt
  alias Char = LibC::Char
  alias Int = LibC::Int
  alias UInt = LibC::UInt
  alias SizeT = LibC::SizeT

  {% if LibLLVM::IS_LT_90 %}
    fun di_builder_create_enumerator = LLVMExtDIBuilderCreateEnumerator(builder : LibLLVM::DIBuilderRef, name : Char*, name_len : SizeT, value : Int64, is_unsigned : LibLLVM::Bool) : LibLLVM::MetadataRef
    fun clear_current_debug_location = LLVMExtClearCurrentDebugLocation(b : LibLLVM::BuilderRef)
  {% end %}

  fun create_operand_bundle = LLVMExtCreateOperandBundle(tag : Char*, tag_len : SizeT,
                                                         args : LibLLVM::ValueRef*,
                                                         num_args : UInt) : LibLLVM::OperandBundleRef

  fun dispose_operand_bundle = LLVMExtDisposeOperandBundle(bundle : LibLLVM::OperandBundleRef)

  fun build_call_with_operand_bundles = LLVMExtBuildCallWithOperandBundles(LibLLVM::BuilderRef, LibLLVM::TypeRef, fn : LibLLVM::ValueRef,
                                                                           args : LibLLVM::ValueRef*, num_args : UInt,
                                                                           bundles : LibLLVM::OperandBundleRef*, num_bundles : UInt,
                                                                           name : Char*) : LibLLVM::ValueRef

  fun build_invoke_with_operand_bundles = LLVMExtBuildInvokeWithOperandBundles(LibLLVM::BuilderRef, ty : LibLLVM::TypeRef, fn : LibLLVM::ValueRef,
                                                                               args : LibLLVM::ValueRef*, num_args : UInt,
                                                                               then : LibLLVM::BasicBlockRef, catch : LibLLVM::BasicBlockRef,
                                                                               bundles : LibLLVM::OperandBundleRef*, num_bundles : UInt,
                                                                               name : Char*) : LibLLVM::ValueRef

  fun set_target_machine_global_isel = LLVMExtSetTargetMachineGlobalISel(t : LibLLVM::TargetMachineRef, enable : LibLLVM::Bool)

  {% unless LibLLVM::IS_LT_180 %}
    # Runs the given pass pipeline with PGO instrumentation (mode = 0) or
    # profile-guided optimization (mode = 1). Returns null on success.
    fun run_passes_with_pgo = LLVMExtRunPassesWithPGO(mod : LibLLVM::ModuleRef, passes : Char*,
                                                      tm : LibLLVM::TargetMachineRef,
                                                      profile_file : Char*, mode : LibC::Int,
                                                      loop_unrolling : LibLLVM::Bool,
                                                      loop_vectorization : LibLLVM::Bool,
                                                      slp_vectorization : LibLLVM::Bool) : LibLLVM::ErrorRef
  {% end %}
end
