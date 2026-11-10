#define HG_AIR_NO_MAIN
#include "air_transform.cpp"
#include "HGOnDeviceAIR.h"
#include <llvm/Support/SHA256.h>
#include <cstring>
#include <cstdlib>
#include <stdexcept>
#include <map>
#include <vector>
#include <algorithm>
#include <mutex>
#include <llvm/Support/ErrorHandling.h>
namespace {
using Bytes=std::vector<uint8_t>;
static void fatalAIR(void*,const char*reason,bool){
 if(llvm::hengeAirBudgetActive())throw std::runtime_error(reason?reason:"AIR compiler fatal error");
 std::abort(); // Preserve LLVM semantics outside this owned C ABI scope.
}
struct BudgetScope {
 BudgetScope(){static std::once_flag once;std::call_once(once,[]{llvm::install_fatal_error_handler(fatalAIR);});llvm::hengeAirBudgetBegin(1000000,5000);}
 ~BudgetScope(){llvm::hengeAirBudgetEnd();}
};
void need(bool b,const char*s){if(!b)throw std::runtime_error(s);}
uint64_t u(const Bytes&b,size_t p,size_t n){need(n<=8&&p<=b.size()&&n<=b.size()-p,"integer outside input");uint64_t v=0;for(size_t i=0;i<n;i++)v|=uint64_t(b[p+i])<<(8*i);return v;}
void put(Bytes&b,size_t p,size_t n,uint64_t v){need(p<=b.size()&&n<=b.size()-p,"integer outside output");for(size_t i=0;i<n;i++)b[p+i]=uint8_t(v>>(8*i));}
struct Tag {std::string key;size_t pos,size;};
std::vector<Tag> tags(const Bytes&b,size_t start,size_t end){need(start<=end&&end<=b.size(),"tag extent invalid");std::vector<Tag>t;size_t p=start;std::set<std::string>seen;
 while(p+4<=end){std::string key((char*)b.data()+p,4);if(key=="ENDT"){need(p+4==end,"trailing tag bytes");return t;}need(p+6<=end,"short tag");size_t n=u(b,p+4,2);need(n<=end-p-6,"tag bounds");need(seen.insert(key).second,"duplicate tag");t.push_back({key,p+6,n});p+=6+n;}throw std::runtime_error("no ENDT");}
struct FunctionRec {std::string name;unsigned type;uint64_t oldOffset,oldSize;std::vector<Tag>fields;};
struct Region {size_t oldSize,newOffset;Bytes bytes;};
}
extern "C" int HGOnDeviceAIRConvert(const void*input,size_t length,int ios,int gl,void**output,size_t*outLength,char**profileJSON,char**errorMessage){
 if(!output||!outLength||!profileJSON||!errorMessage)return 1;*output=nullptr;*outLength=0;*profileJSON=nullptr;*errorMessage=nullptr;
 try{
  BudgetScope budget;
  need(input&&length>=88&&length<=8*1024*1024,"input size unsupported");Bytes b((const uint8_t*)input,(const uint8_t*)input+length);
  need(std::memcmp(b.data(),"MTLB",4)==0,"not MTLB");need(u(b,6,2)==2&&u(b,8,2)==7&&u(b,10,1)==0,"only executable MTLB2.7 supported");need(u(b,16,8)==length,"declared length mismatch");need(u(b,4,2)==0x8001||u(b,4,2)==1,"unsupported platform");
  size_t fo=u(b,24,8),fs=u(b,32,8),po=u(b,40,8),ps=u(b,48,8),vo=u(b,56,8),vs=u(b,64,8),bo=u(b,72,8),bs=u(b,80,8);
  need(fo==88&&fs<=length-fo&&po>=fo+fs+4&&po<=length&&ps<=length-po&&vo==po+ps&&vs<=length-vo&&bo==vo+vs&&bs<=length-bo,"unsupported section layout");
  size_t count=u(b,fo,4),p=fo+4;need(count>0&&count<=4096,"function count unsupported");std::vector<FunctionRec>funcs;std::map<size_t,Region>regions;
  for(size_t i=0;i<count;i++){
   size_t n=u(b,p,4);need(n>=8&&p+n<=fo+fs+4,"function record bounds");auto fields=tags(b,p+4,p+n);p+=n;FunctionRec f{};f.fields=fields;bool name=false,type=false,hash=false,off=false,size=false,vers=false;size_t hashPos=0;
   for(auto&t:fields){
    if(t.key=="NAME"){need(t.size>1&&t.size<=1025&&b[t.pos+t.size-1]==0,"invalid name");f.name=std::string((char*)b.data()+t.pos,t.size-1);need(f.name.find('\0')==std::string::npos,"embedded NUL");name=true;}
    else if(t.key=="TYPE"){need(t.size==1&&b[t.pos]<=2,"only vertex/fragment/kernel supported");f.type=b[t.pos];type=true;}
    else if(t.key=="HASH"){need(t.size==32,"HASH length");hash=true;hashPos=t.pos;}
    else if(t.key=="MDSZ"){need(t.size==8,"MDSZ length");f.oldSize=u(b,t.pos,8);size=true;}
    else if(t.key=="OFFT"){need(t.size==24,"OFFT length");need(u(b,t.pos,8)<ps&&u(b,t.pos+8,8)<vs,"metadata offset outside section");f.oldOffset=u(b,t.pos+16,8);off=true;}
    else if(t.key=="VERS"){need(t.size==8&&u(b,t.pos,2)==2&&u(b,t.pos+2,2)==6,"only AIR2.6 supported");vers=true;}
   }
   need(name&&type&&hash&&off&&size&&vers,"missing function fields");need(f.oldOffset<=bs&&f.oldSize<=bs-f.oldOffset&&f.oldSize>=20&&f.oldSize<=4*1024*1024,"AIR range invalid");auto digest=SHA256::hash(ArrayRef<uint8_t>(b.data()+bo+f.oldOffset,f.oldSize));need(std::memcmp(digest.data(),b.data()+hashPos,32)==0,"AIR digest mismatch");
   auto [it,inserted]=regions.emplace(f.oldOffset,Region{size_t(f.oldSize),0,{}});need(inserted||it->second.oldSize==f.oldSize,"conflicting shared AIR size");funcs.push_back(std::move(f));
  }
  need(regions.size()<=256,"AIR module count limit");
  need(p==fo+fs+4,"function-list tail");auto ext=tags(b,p,po);for(auto&t:ext)need(t.key=="UUID"||t.key=="RLST","unsupported header extension");
  Bytes bitcode;json::Array names;std::set<std::string>lowered;size_t cursor=0;LLVMContext context;
  for(auto&[offset,region]:regions){
   llvm::hengeAirBudgetCheck();
   need(offset==cursor,"uncovered/overlapping bitcode");cursor+=region.oldSize;StringRef raw((char*)b.data()+bo+offset,region.oldSize);auto buffer=MemoryBuffer::getMemBuffer(raw,"ondevice-air",false);auto parsed=parseBitcodeFile(buffer->getMemBufferRef(),context);if(!parsed)throw std::runtime_error(toString(parsed.takeError()));auto&m=**parsed;need(!verifyModule(m,&errs()),"LLVM verify failed");json::Object report;need(::transform(m,gl!=0,report),"AIR transformation rejected");
   if(auto*a=report.getArray("vertex_functions"))for(auto&x:*a)lowered.insert(x.getAsString()->str());
   size_t instructions=0;for(auto&f:m)for(auto&block:f)instructions+=block.size();need(instructions<=131072,"AIR instruction limit");
   if(ios)m.setTargetTriple("air64_v26-apple-ios17.0.0");SmallVector<char,0>out;raw_svector_ostream stream(out);WriteBitcodeToFile140(m,stream);region.newOffset=bitcode.size();region.bytes.assign(out.begin(),out.end());need(region.bytes.size()>=20&&u(region.bytes,0,4)==0x0b17c0de,"writer did not emit AIR wrapper");bitcode.insert(bitcode.end(),region.bytes.begin(),region.bytes.end());
  }
  need(lowered.size()<=16,"profile vertex count limit");
  need(bitcode.size()<=16*1024*1024,"AIR output limit");
  need(cursor==bs,"uncovered AIR tail");for(auto&name:lowered){bool found=false;for(auto&f:funcs)if(f.name==name&&f.type==0)found=true;need(found,"profile vertex missing from container");names.push_back(name);}
  Bytes out(b.begin(),b.begin()+bo);out.insert(out.end(),bitcode.begin(),bitcode.end());out.insert(out.end(),b.begin()+bo+bs,b.end());
  for(auto&f:funcs){auto&r=regions.at(f.oldOffset);for(auto&t:f.fields){if(t.key=="HASH"){auto h=SHA256::hash(r.bytes);std::copy(h.begin(),h.end(),out.begin()+t.pos);}else if(t.key=="MDSZ")put(out,t.pos,8,r.bytes.size());else if(t.key=="OFFT")put(out,t.pos+16,8,r.newOffset);}}
  bool reflection=false;for(auto&t:ext)if(t.key=="RLST"){need(t.size==16&&u(b,t.pos,8)==bo+bs&&u(b,t.pos+8,8)==length-bo-bs,"unsupported RLST extent");put(out,t.pos,8,bo+bitcode.size());reflection=true;}need(reflection||bo+bs==length,"unknown trailing bytes");
  if(ios){put(out,4,2,1);put(out,11,1,0x82);put(out,12,2,17);put(out,14,2,0);}put(out,16,8,out.size());put(out,80,8,bitcode.size());
  json::Object profile;profile["schema"]=1;profile["gl_clip_zero_to_one"]=!lowered.empty();profile["vertex_functions"]=std::move(names);profile["viewport_contract"]=lowered.empty()?json::Value(nullptr):json::Value("gl_half_range_v1");std::string json;raw_string_ostream js(json);js<<formatv("{0}",json::Value(std::move(profile)));js.flush();
  void*result=std::malloc(out.size());need(result,"allocation failed");char*profileString=strdup(json.c_str());if(!profileString){free(result);throw std::runtime_error("allocation failed");}memcpy(result,out.data(),out.size());*output=result;*outLength=out.size();*profileJSON=profileString;return 0;
 }catch(const std::exception&e){*errorMessage=strdup(e.what());return 1;}
}
