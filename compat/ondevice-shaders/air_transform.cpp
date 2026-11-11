// Isolated AIR2.6 experiment. LLVM14 fork reader/writer; no Apple runtime tools.
#include <llvm/Bitcode/BitcodeReader.h>
#include <llvm/Bitcode/BitcodeWriter.h>
#include <llvm/IR/IRBuilder.h>
#include <llvm/IR/Verifier.h>
#include <llvm/IR/Module.h>
#include <llvm/Support/Error.h>
#include <llvm/Support/MemoryBuffer.h>
#include <llvm/Support/FileSystem.h>
#include <llvm/Support/raw_ostream.h>
#include <llvm/Support/JSON.h>
#include <set>
using namespace llvm;
static constexpr const char *Marker="henge.gl_clip_zero_to_one";
static bool reject(StringRef msg){errs()<<msg<<"\n";return false;}
static bool transform(Module&m,bool applyGL,json::Object &report){
 report["original_triple"]=m.getTargetTriple();
 auto*v=m.getNamedMetadata("air.version");
 if(!v||v->getNumOperands()!=1||v->getOperand(0)->getNumOperands()!=3)return reject("unsupported AIR version shape");
 auto num=[](Metadata*x)->int {auto*c=dyn_cast_or_null<ConstantAsMetadata>(x);auto*i=c?dyn_cast<ConstantInt>(c->getValue()):nullptr;return i?int(i->getZExtValue()):-1;};
 auto*node=v->getOperand(0);
 if(num(node->getOperand(0))!=2||num(node->getOperand(1))!=6||num(node->getOperand(2))!=0)return reject("prototype supports only AIR2.6.0");
 json::Array names;bool changed=false;
 auto*lang=m.getNamedMetadata("air.language_version");bool gl=false;
 if(lang)for(auto*n:lang->operands())if(n->getNumOperands())if(auto*s=dyn_cast_or_null<MDString>(n->getOperand(0)))gl|=s->getString()=="OpenGL GLSL";
 if(gl&&applyGL){
  if(lang->getNumOperands()!=1)return reject("ambiguous language metadata");
  auto*vertices=m.getNamedMetadata("air.vertex");std::set<Function*>seen;
  if(vertices)for(auto*entry:vertices->operands()){
   if(entry->getNumOperands()<2)return reject("incomplete vertex metadata");
   auto*vm=dyn_cast_or_null<ValueAsMetadata>(entry->getOperand(0));auto*f=vm?dyn_cast<Function>(vm->getValue()->stripPointerCasts()):nullptr;
   auto*outputs=dyn_cast_or_null<MDNode>(entry->getOperand(1));
   if(!f||f->isDeclaration()||!outputs||!seen.insert(f).second)return reject("invalid vertex entrypoint");
   int slot=-1;unsigned tags=0;
   for(unsigned i=0;i<outputs->getNumOperands();i++){
    auto*n=dyn_cast_or_null<MDNode>(outputs->getOperand(i));if(!n)return reject("invalid output metadata");bool position=false;
    for(auto&o:n->operands())if(auto*s=dyn_cast_or_null<MDString>(o))if(s->getString()=="air.position"){position=true;tags++;}
    if(position){if(slot!=-1)return reject("multiple position outputs");slot=i;
     if(n->getNumOperands()&&isa<ConstantAsMetadata>(n->getOperand(0))&&num(n->getOperand(0))!=int(i))return reject("position ordinal mismatch");}
   }
   if(slot<0||tags!=1)return reject("missing position");
   Type*ret=f->getReturnType();auto*st=dyn_cast<StructType>(ret);Type*pos=nullptr;
   if(st){if(st->isOpaque()||st->getNumElements()!=outputs->getNumOperands())return reject("output aggregate mismatch");pos=st->getElementType(slot);}
   else if(slot==0&&outputs->getNumOperands()==1)pos=ret;
   auto*vec=dyn_cast_or_null<FixedVectorType>(pos);if(!vec||vec->getNumElements()!=4||!vec->getElementType()->isFloatTy())return reject("position must be float4");
   if(f->hasFnAttribute(Marker)){if(f->getFnAttribute(Marker).getValueAsString()!="1")return reject("unknown marker");}
   else {
    unsigned returns=0;
    for(auto&bb:*f)if(auto*r=dyn_cast<ReturnInst>(bb.getTerminator())){
     if(!r->getReturnValue())return reject("invalid return");IRBuilder<>ir(r);Value*old=r->getReturnValue();Value*p=st?ir.CreateExtractValue(old,{unsigned(slot)},"henge.position"):old;
     Value*z=ir.CreateExtractElement(p,ir.getInt32(2));Value*w=ir.CreateExtractElement(p,ir.getInt32(3));Value*n=ir.CreateFMul(ir.CreateFAdd(z,w),ConstantFP::get(ir.getFloatTy(),0.5));Value*next=ir.CreateInsertElement(p,n,ir.getInt32(2));
     r->setOperand(0,st?ir.CreateInsertValue(old,next,{unsigned(slot)}):next);returns++;
    }
    if(!returns)return reject("vertex has no returns");f->addFnAttr(Marker,"1");changed=true;
   }
   names.push_back(f->getName().str());
  }
 }
 report["gl_language"]=gl;report["gl_clip_zero_to_one"]=!names.empty();report["gl_changed"]=changed;report["vertex_functions"]=std::move(names);
 return !verifyModule(m,&errs());
}
#ifndef HG_AIR_NO_MAIN
int main(int argc,char**argv){
 if(argc!=5){errs()<<"air_transform input.air output.air target-or-preserve apply-gl-0-or-1\n";return 64;}
 LLVMContext c;auto b=MemoryBuffer::getFile(argv[1]);if(!b){errs()<<b.getError().message();return 2;}auto parsed=parseBitcodeFile((*b)->getMemBufferRef(),c);if(!parsed){errs()<<toString(parsed.takeError());return 2;}auto&m=**parsed;if(verifyModule(m,&errs()))return 2;
 json::Object report;if(!transform(m,StringRef(argv[4])=="1",report))return 3;
 if(StringRef(argv[3])!="preserve"){
  if(StringRef(argv[3])!="air64_v26-apple-ios17.0.0"&&StringRef(argv[3])!="air64_v26-apple-macosx14.0.0")return 64;m.setTargetTriple(argv[3]);
 }
 report["output_triple"]=m.getTargetTriple();report["air_version_preserved"]=true;
 std::error_code error;raw_fd_ostream out(argv[2],error,sys::fs::OF_None);if(error)return 4;WriteBitcodeToFile140(m,out);out.flush();if(out.has_error())return 4;outs()<<formatv("{0:2}",json::Value(std::move(report)))<<"\n";
}

#endif
