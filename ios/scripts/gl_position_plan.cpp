// Inspect LLVM AIR metadata and emit an edit plan, not a new LLVM-version bitcode.
#include <llvm/IR/Constants.h>
#include <llvm/IR/Function.h>
#include <llvm/IR/Instructions.h>
#include <llvm/IR/LLVMContext.h>
#include <llvm/IR/Metadata.h>
#include <llvm/IR/Module.h>
#include <llvm/IR/Verifier.h>
#include <llvm/IRReader/IRReader.h>
#include <llvm/Support/JSON.h>
#include <llvm/Support/SourceMgr.h>
#include <llvm/Support/raw_ostream.h>
#include <set>
using namespace llvm;
static constexpr const char*Marker="henge.gl_clip_zero_to_one";
static bool fail(StringRef why){errs()<<why<<"\n";return false;}
static std::string typeText(Type*t){std::string s;raw_string_ostream o(s);t->print(o);return s;}
static std::string operandText(Value*v,Module*m){std::string s;raw_string_ostream o(s);v->printAsOperand(o,false,m);return s;}
static bool float4(Type*t){auto*v=dyn_cast<FixedVectorType>(t);return v&&v->getNumElements()==4&&v->getElementType()->isFloatTy();}
static bool plan(Module&m,json::Object&out){
 out["schema"]=1;out["target_triple"]=m.getTargetTriple().str();out["marker"]=Marker;out["gl_clip_zero_to_one"]=false;out["changed"]=false;json::Array functions;
 auto*lang=m.getNamedMetadata("air.language_version");bool gl=false;
 if(lang)for(auto*n:lang->operands())if(n->getNumOperands())if(auto*s=dyn_cast_or_null<MDString>(n->getOperand(0)))gl|=s->getString()=="OpenGL GLSL";
 if(!gl){out["reason"]="not_opengl_glsl";out["functions"]=std::move(functions);return true;}
 if(lang->getNumOperands()!=1)return fail("ambiguous OpenGL language metadata");
 auto*vertices=m.getNamedMetadata("air.vertex");
 if(!vertices||vertices->getNumOperands()==0){out["reason"]="no_vertex_entrypoints";out["functions"]=std::move(functions);return true;}
 std::set<Function*>seen;bool changed=false;
 for(auto*entry:vertices->operands()){
  if(entry->getNumOperands()<2)return fail("truncated vertex metadata");
  auto*vm=dyn_cast_or_null<ValueAsMetadata>(entry->getOperand(0));auto*f=vm?dyn_cast<Function>(vm->getValue()->stripPointerCasts()):nullptr;
  auto*outputs=dyn_cast_or_null<MDNode>(entry->getOperand(1));
  if(!f||f->isDeclaration()||!outputs||!seen.insert(f).second)return fail("invalid/duplicate vertex entrypoint");
  int slot=-1;unsigned positionTags=0;
  for(unsigned i=0;i<outputs->getNumOperands();i++){
   auto*n=dyn_cast_or_null<MDNode>(outputs->getOperand(i));if(!n)return fail("unsupported output metadata shape");
   bool position=false;for(auto&op:n->operands())if(auto*s=dyn_cast_or_null<MDString>(op))if(s->getString()=="air.position"){position=true;positionTags++;}
   if(position){if(slot!=-1)return fail("multiple position outputs");slot=i;
    if(n->getNumOperands())if(auto*c=dyn_cast_or_null<ConstantAsMetadata>(n->getOperand(0))){auto*idx=dyn_cast<ConstantInt>(c->getValue());if(!idx||idx->getZExtValue()!=i)return fail("explicit position ordinal disagrees with output list");}
   }
  }
  if(slot<0||positionTags!=1)return fail("missing or duplicate air.position metadata");
  Type*ret=f->getReturnType();bool aggregate=isa<StructType>(ret);Type*position=nullptr;
  if(auto*s=dyn_cast<StructType>(ret)){if(s->isOpaque()||s->getNumElements()!=outputs->getNumOperands()||unsigned(slot)>=s->getNumElements())return fail("return aggregate does not match output metadata");position=s->getElementType(slot);}
  else if(outputs->getNumOperands()==1&&slot==0)position=ret;
  if(!position||!float4(position))return fail("position must be an exact fixed float4 return value");
  bool marked=f->hasFnAttribute(Marker);if(marked&&f->getFnAttribute(Marker).getValueAsString()!="1")return fail("unknown position-lowering marker version");
  json::Array returns;for(auto&block:*f)for(auto&i:block)if(auto*r=dyn_cast<ReturnInst>(&i)){if(!r->getReturnValue()||r->getReturnValue()->getType()!=ret)return fail("invalid vertex return");returns.push_back(operandText(r->getReturnValue(),&m));}
  if(returns.empty())return fail("vertex entrypoint has no return path");
  json::Object item;item["name"]=f->getName().str();item["operand"]=operandText(f,&m);item["return_type"]=typeText(ret);item["position_slot"]=slot;item["aggregate"]=aggregate;item["already_marked"]=marked;item["returns"]=std::move(returns);functions.push_back(std::move(item));changed|=!marked;
 }
 out["gl_clip_zero_to_one"]=true;out["changed"]=changed;out["reason"]=changed?"validated_gl_vertex_returns":"already_marked";out["functions"]=std::move(functions);out["required_viewport_contract"]="near'=2*rawNear-rawFar;far'=rawFar";return true;
}
int main(int argc,char**argv){if(argc!=2)return 64;LLVMContext c;SMDiagnostic d;auto m=parseIRFile(argv[1],d,c);if(!m){d.print(argv[0],errs());return 2;}if(verifyModule(*m,&errs()))return 2;json::Object out;if(!plan(*m,out))return 3;outs()<<formatv("{0:2}",json::Value(std::move(out)))<<"\n";}
