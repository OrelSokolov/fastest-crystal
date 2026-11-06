#include <llvm/Config/llvm-config.h>
#include <llvm/IR/IRBuilder.h>
#include <llvm/Target/TargetMachine.h>
#include <llvm-c/TargetMachine.h>

using namespace llvm;

#define LLVM_VERSION_GE(major, minor) \
  (LLVM_VERSION_MAJOR > (major) || LLVM_VERSION_MAJOR == (major) && LLVM_VERSION_MINOR >= (minor))

#if !LLVM_VERSION_GE(9, 0)
#include <llvm/IR/DIBuilder.h>
#endif

#if LLVM_VERSION_GE(16, 0)
#define makeArrayRef ArrayRef
#endif

#if !LLVM_VERSION_GE(18, 0)
typedef struct LLVMOpaqueOperandBundle *LLVMOperandBundleRef;
DEFINE_SIMPLE_CONVERSION_FUNCTIONS(OperandBundleDef, LLVMOperandBundleRef)
#endif

#if LLVM_VERSION_GE(18, 0)
#include <llvm-c/Error.h>
#include <llvm/IR/Module.h>
#include <llvm/Passes/PassBuilder.h>
#include <llvm/Passes/StandardInstrumentations.h>
#include <llvm/Support/CommandLine.h>
#include <llvm/Support/VirtualFileSystem.h>
#endif

extern "C" {

#if !LLVM_VERSION_GE(9, 0)
LLVMMetadataRef LLVMExtDIBuilderCreateEnumerator(LLVMDIBuilderRef Builder,
                                                 const char *Name, size_t NameLen,
                                                 int64_t Value,
                                                 LLVMBool IsUnsigned) {
  return wrap(unwrap(Builder)->createEnumerator({Name, NameLen}, Value,
                                                IsUnsigned != 0));
}

void LLVMExtClearCurrentDebugLocation(LLVMBuilderRef B) {
  unwrap(B)->SetCurrentDebugLocation(DebugLoc::get(0, 0, nullptr));
}
#endif

#if !LLVM_VERSION_GE(18, 0)
LLVMOperandBundleRef LLVMExtCreateOperandBundle(const char *Tag, size_t TagLen,
                                                LLVMValueRef *Args,
                                                unsigned NumArgs) {
  return wrap(new OperandBundleDef(std::string(Tag, TagLen),
                                   makeArrayRef(unwrap(Args), NumArgs)));
}

void LLVMExtDisposeOperandBundle(LLVMOperandBundleRef Bundle) {
  delete unwrap(Bundle);
}

LLVMValueRef
LLVMExtBuildCallWithOperandBundles(LLVMBuilderRef B, LLVMTypeRef Ty,
                                   LLVMValueRef Fn, LLVMValueRef *Args,
                                   unsigned NumArgs, LLVMOperandBundleRef *Bundles,
                                   unsigned NumBundles, const char *Name) {
  FunctionType *FTy = unwrap<FunctionType>(Ty);
  SmallVector<OperandBundleDef, 8> OBs;
  for (auto *Bundle : makeArrayRef(Bundles, NumBundles)) {
    OperandBundleDef *OB = unwrap(Bundle);
    OBs.push_back(*OB);
  }
  return wrap(unwrap(B)->CreateCall(
      FTy, unwrap(Fn), makeArrayRef(unwrap(Args), NumArgs), OBs, Name));
}

LLVMValueRef LLVMExtBuildInvokeWithOperandBundles(
    LLVMBuilderRef B, LLVMTypeRef Ty, LLVMValueRef Fn, LLVMValueRef *Args,
    unsigned NumArgs, LLVMBasicBlockRef Then, LLVMBasicBlockRef Catch,
    LLVMOperandBundleRef *Bundles, unsigned NumBundles, const char *Name) {
  SmallVector<OperandBundleDef, 8> OBs;
  for (auto *Bundle : makeArrayRef(Bundles, NumBundles)) {
    OperandBundleDef *OB = unwrap(Bundle);
    OBs.push_back(*OB);
  }
  return wrap(unwrap(B)->CreateInvoke(
      unwrap<FunctionType>(Ty), unwrap(Fn), unwrap(Then), unwrap(Catch),
      makeArrayRef(unwrap(Args), NumArgs), OBs, Name));
}
#endif

#if !LLVM_VERSION_GE(18, 0)
static TargetMachine *unwrap(LLVMTargetMachineRef P) {
  return reinterpret_cast<TargetMachine *>(P);
}

void LLVMExtSetTargetMachineGlobalISel(LLVMTargetMachineRef T, LLVMBool Enable) {
  unwrap(T)->setGlobalISel(Enable);
}
#endif

#if LLVM_VERSION_GE(18, 0)
// Same as LLVMRunPasses, but threads a PGOOptions through the PassBuilder.
// Mode: 0 = instrument (IRInstr, generate profiles), 1 = use profiles (IRUse).
// Returns an LLVMErrorRef (null on success).
LLVMErrorRef LLVMExtRunPassesWithPGO(LLVMModuleRef Mod, const char *Passes,
                                     LLVMTargetMachineRef TM,
                                     const char *ProfileFile, int Mode,
                                     unsigned LoopUnrolling,
                                     unsigned LoopVectorization,
                                     unsigned SLPVectorization) {
  Module *M = unwrap(Mod);
  TargetMachine *Machine = reinterpret_cast<TargetMachine *>(TM);

  PipelineTuningOptions PTO;
  PTO.LoopUnrolling = LoopUnrolling;
  PTO.LoopVectorization = LoopVectorization;
  PTO.SLPVectorization = SLPVectorization;

  std::optional<PGOOptions> PGOOpt;
  if (Mode == 0) {
    // Crystal binaries issue a burst of instrumented indirect calls at
    // startup (fiber scheduler, worker threads); the value-profiling runtime
    // races there and corrupts its vnode lists (SIGSEGV in
    // __llvm_profile_instrument_target). Value profiles add little for
    // Crystal code, so instrumentation runs with value profiling disabled.
    static std::once_flag DisableVPOnce;
    std::call_once(DisableVPOnce, [] {
      const char *Argv[] = {"fastest-crystal", "-disable-vp=true"};
      cl::ParseCommandLineOptions(2, Argv, "PGO instrumentation\n");
    });

    std::string File = ProfileFile && ProfileFile[0] ? ProfileFile : "default_%m.profraw";
    PGOOpt = PGOOptions(File, "", "", "", vfs::getRealFileSystem(),
                        PGOOptions::IRInstr);
  } else {
    PGOOpt = PGOOptions(ProfileFile, "", "", "", vfs::getRealFileSystem(),
                        PGOOptions::IRUse);
  }

  PassInstrumentationCallbacks PIC;
  StandardInstrumentations SI(M->getContext(), /*DebugLogging*/ false);
  SI.registerCallbacks(PIC);
  PassBuilder PB(Machine, PTO, PGOOpt, &PIC);

  LoopAnalysisManager LAM;
  FunctionAnalysisManager FAM;
  CGSCCAnalysisManager CGAM;
  ModuleAnalysisManager MAM;
  PB.registerModuleAnalyses(MAM);
  PB.registerCGSCCAnalyses(CGAM);
  PB.registerFunctionAnalyses(FAM);
  PB.registerLoopAnalyses(LAM);
  PB.crossRegisterProxies(LAM, FAM, CGAM, MAM);

  ModulePassManager MPM;
  if (auto Err = PB.parsePassPipeline(MPM, Passes))
    return wrap(std::move(Err));

  MPM.run(*M, MAM);
  return nullptr;
}
#endif

} // extern "C"
