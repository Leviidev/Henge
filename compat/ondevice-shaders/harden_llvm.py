#!/usr/bin/env python3
"""Reproducible bounded AIR embedding patch over pinned LLVM source; no fuzzing."""
from pathlib import Path
import difflib,json,hashlib
root=Path('llvm-source/llvm');changes=[]
def edit(rel,fn):
 p=root/rel;old=p.read_text();new=fn(old);assert new!=old,rel;p.write_text(new);changes.append((rel,old,new))
def replace(s,a,b,n=1):assert s.count(a)==n,(a,s.count(a));return s.replace(a,b)
edit('include/llvm/Support/ErrorHandling.h',lambda s:replace(s,'#ifndef NDEBUG\n#define llvm_unreachable(msg)', '#if defined(HENGE_AIR_EMBEDDED)\n#ifdef NDEBUG\n#define llvm_unreachable(msg) ::llvm::report_fatal_error("unreachable AIR compiler state")\n#else\n#define llvm_unreachable(msg) ::llvm::report_fatal_error(msg)\n#endif\n#elif !defined(NDEBUG)\n#define llvm_unreachable(msg)'))
edit('include/llvm/Support/ErrorHandling.h',lambda s:replace(s,'namespace llvm {','namespace llvm {\n// Scoped cooperative resource budget for the isolated AIR embedding.\nvoid hengeAirBudgetBegin(uint64_t operations, uint64_t milliseconds);\nvoid hengeAirBudgetEnd();\nbool hengeAirBudgetActive();\nvoid hengeAirBudgetCheck();'))
# uint64_t header requirement must be explicit.
edit('include/llvm/Support/ErrorHandling.h',lambda s:replace(s,'#define LLVM_SUPPORT_ERRORHANDLING_H','#define LLVM_SUPPORT_ERRORHANDLING_H\n#include <cstdint>'))
code='''
namespace {
thread_local bool HengeBudgetActive = false;
thread_local uint64_t HengeOperations = 0;
thread_local std::chrono::steady_clock::time_point HengeDeadline;
}
void llvm::hengeAirBudgetBegin(uint64_t operations, uint64_t milliseconds) {
  HengeOperations = operations;
  HengeDeadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(milliseconds);
  HengeBudgetActive = true;
}
void llvm::hengeAirBudgetEnd() { HengeBudgetActive = false; }
bool llvm::hengeAirBudgetActive() { return HengeBudgetActive; }
void llvm::hengeAirBudgetCheck() {
  if (!HengeBudgetActive) return;
  if (HengeOperations == 0) report_fatal_error("AIR reader operation budget exceeded");
  --HengeOperations;
  if ((HengeOperations & 1023) == 0 && std::chrono::steady_clock::now() > HengeDeadline)
    report_fatal_error("AIR reader cooperative deadline exceeded");
}
'''
edit('lib/Support/ErrorHandling.cpp',lambda s:replace(s,'#include <new>','#include <new>\n#include <chrono>')+code)
edit('lib/Support/ErrorHandling.cpp',lambda s:replace(s,'                                     unsigned line) {','                                     unsigned line) {\n#ifdef HENGE_AIR_EMBEDDED\n  report_fatal_error(msg ? msg : "unreachable AIR compiler state");\n#endif'))
# Per-record allocation/structure caps precede vector growth and iteration.
def stream(s):
 s=replace(s,'Error BitstreamCursor::EnterSubBlock(unsigned BlockID, unsigned *NumWordsP) {','Error BitstreamCursor::EnterSubBlock(unsigned BlockID, unsigned *NumWordsP) {\n  hengeAirBudgetCheck();\n  if (hengeAirBudgetActive() && BlockScope.size() >= 64) report_fatal_error("AIR nesting limit");')
 s=replace(s,'  if (AbbrevID == bitc::UNABBREV_RECORD) {','  hengeAirBudgetCheck();\n  if (AbbrevID == bitc::UNABBREV_RECORD) {',2)
 s=replace(s,'    Vals.reserve(Vals.size() + NumElts);','    if (hengeAirBudgetActive() && NumElts > 262144) report_fatal_error("AIR record operand limit");\n    Vals.reserve(Vals.size() + NumElts);',2)
 s=replace(s,'Error BitstreamCursor::ReadAbbrevRecord() {','Error BitstreamCursor::ReadAbbrevRecord() {\n  hengeAirBudgetCheck();\n  if (hengeAirBudgetActive() && CurAbbrevs.size() >= 4096) report_fatal_error("AIR abbreviation count limit");')
 s=replace(s,'  unsigned NumOpInfo = MaybeNumOpInfo.get();','  unsigned NumOpInfo = MaybeNumOpInfo.get();\n  if (hengeAirBudgetActive() && NumOpInfo > 256) report_fatal_error("AIR abbreviation operand limit");')
 return s
edit('lib/Bitstream/Reader/BitstreamReader.cpp',stream)
edit('lib/Bitcode/Reader/ValueList.h',lambda s:replace(replace(s,'    ValuePtrs.resize(N);','    if (hengeAirBudgetActive() && N > 131072) report_fatal_error("AIR value table limit");\n    ValuePtrs.resize(N);',2),'  void push_back(Value *V) { ValuePtrs.emplace_back(V); }','  void push_back(Value *V) { if (hengeAirBudgetActive() && ValuePtrs.size() >= 131072) report_fatal_error("AIR value table limit"); ValuePtrs.emplace_back(V); }'))
def metadata(s):
 s=replace(s,'  void resize(unsigned N) { MetadataPtrs.resize(N); }','  void resize(unsigned N) { if (hengeAirBudgetActive() && N > 131072) report_fatal_error("AIR metadata table limit"); MetadataPtrs.resize(N); }')
 s=replace(s,'  void push_back(Metadata *MD) { MetadataPtrs.emplace_back(MD); }','  void push_back(Metadata *MD) { if (hengeAirBudgetActive() && MetadataPtrs.size() >= 131072) report_fatal_error("AIR metadata table limit"); MetadataPtrs.emplace_back(MD); }')
 s=replace(s,'        MDStringRef.reserve(NumStrings);','        if (hengeAirBudgetActive() && NumStrings > 131072) report_fatal_error("AIR metadata string limit");\n        MDStringRef.reserve(NumStrings);')
 return s
edit('lib/Bitcode/Reader/MetadataLoader.cpp',metadata)
edit('lib/Bitcode/Reader/BitcodeReader.cpp',lambda s:replace(replace(s,'      TypeList.resize(Record[0]);','      if (hengeAirBudgetActive() && Record[0] > 16384) return error("AIR type table limit");\n      TypeList.resize(Record[0]);'),'      FunctionBBs.resize(Record[0]);','      if (hengeAirBudgetActive() && Record[0] > 16384) return error("AIR basic block limit");\n      FunctionBBs.resize(Record[0]);'))
# Combine repeated edits to same file into one stable diff.
merged={}
for rel,old,new in changes:
 if rel not in merged:merged[rel]=[old,new]
 else:merged[rel][1]=new
patch=''.join(''.join(difflib.unified_diff(old.splitlines(True),new.splitlines(True),fromfile='a/llvm/'+rel,tofile='b/llvm/'+rel))for rel,(old,new)in merged.items())
Path('llvm-air-embedding.patch').write_text(patch)
Path('llvm-hardening-manifest.json').write_text(json.dumps({rel:dict(before_sha256=hashlib.sha256(old.encode()).hexdigest(),after_sha256=hashlib.sha256(new.encode()).hexdigest())for rel,(old,new)in merged.items()},indent=2)+'\n')
