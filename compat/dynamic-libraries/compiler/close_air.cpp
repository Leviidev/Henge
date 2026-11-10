// Isolated closed-graph lowering. Never remove unresolved dynamic imports.
#include <llvm/Bitcode/BitcodeWriter.h>
#include <llvm/IR/Constants.h>
#include <llvm/IR/LLVMContext.h>
#include <llvm/IR/Module.h>
#include <llvm/IR/Verifier.h>
#include <llvm/IRReader/IRReader.h>
#include <llvm/Support/FileSystem.h>
#include <llvm/Support/SourceMgr.h>
#include <llvm/Support/raw_ostream.h>
#include <llvm/Transforms/Utils/ModuleUtils.h>
#include <set>
using namespace llvm;
int main(int argc, char **argv) {
  if (argc != 3)
    return 64;
  LLVMContext c;
  SMDiagnostic e;
  auto m = parseIRFile(argv[1], e, c);
  if (!m) {
    e.print(argv[0], errs());
    return 2;
  }
  std::set<GlobalVariable *> route;
  for (auto &g : m->globals()) {
    if (g.getName().starts_with("air.dyld_")) {
      if (g.getName() != "air.dyld_lib_table" &&
          g.getName() != "air.dyld_str_table" &&
          g.getName() != "air.dyld_flat_table") {
        errs() << "unknown dyld table\n";
        return 3;
      }
      route.insert(&g);
    }
  }
  auto *flat = m->getNamedGlobal("air.dyld_flat_table");
  unsigned n = 0;
  if (!route.empty()) {
    if (!flat || !flat->hasInitializer()) {
      errs() << "missing flat table\n";
      return 3;
    }
    auto *a = dyn_cast<ConstantArray>(flat->getInitializer());
    if (!a) {
      errs() << "unsupported flat table shape\n";
      return 3;
    }
    for (auto &o : a->operands()) {
      auto *f = dyn_cast<Function>(o->stripPointerCasts());
      if (!f || f->isDeclaration() || !f->hasLocalLinkage()) {
        errs() << "unresolved or externally interposable dynamic symbol\n";
        return 3;
      }
      outs() << "resolved " << f->getName() << "\n";
      n++;
    }
  }
  removeFromUsedLists(*m, [&](Constant *v) {
    auto *g = dyn_cast<GlobalVariable>(v->stripPointerCasts());
    return g && route.contains(g);
  });
  for (auto *g : route) {
    g->removeDeadConstantUsers();
    if (!g->use_empty()) {
      errs() << "routing table has semantic IR users\n";
      return 3;
    }
  }
  for (auto *g : route)
    g->eraseFromParent();
  if (verifyModule(*m, &errs()))
    return 3;
  std::error_code ec;
  raw_fd_ostream out(argv[2], ec, sys::fs::OF_None);
  if (ec)
    return 4;
  WriteBitcodeToFile(*m, out);
  outs() << "removed_routing_tables " << route.size()
         << " resolved_definitions " << n << "\n";
  return 0;
}
