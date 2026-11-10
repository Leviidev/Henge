#!/usr/bin/env python3
"""Metadata-selected GL clip normalization in Apple-spelled textual AIR.
Requires paired viewport profile handling. Never deploy vertex-only.
"""
import argparse,hashlib,json,re,subprocess
from pathlib import Path
from shader_compile_runtime import run_tool
ROOT=Path(__file__).resolve().parent
MARKER='henge.gl_clip_zero_to_one'
class Unsupported(ValueError):pass
def sha(b):return hashlib.sha256(b).hexdigest()
def get_plan(path,tool=None):
 p=run_tool([str(tool or ROOT/'gl-position-plan'),str(path)],stage='inspect-position',capture_output=True,text=True)
 if p.returncode:raise Unsupported(p.stderr.strip())
 return json.loads(p.stdout)
def apply(text,plan):
 if not plan['changed']:return text
 lines=text.splitlines(keepends=True);edits={};marked_headers={};seen=set()
 prefix='henge_gl_clip_v1'
 while prefix in text:prefix+='x'
 for ordinal,f in enumerate(plan['functions']):
  if f['already_marked']:continue
  matches=[i for i,l in enumerate(lines)if l.startswith('define ') and (' '+f['operand']+'(')in l]
  if len(matches)!=1:raise Unsupported('cannot bind planned vertex function to one Apple IR header')
  start=matches[0]
  if not lines[start].rstrip().endswith('{'):raise Unsupported('multiline function header is unsupported')
  end=next((i for i in range(start+1,len(lines))if lines[i].strip()=='}'),None)
  if end is None:raise Unsupported('missing function terminator')
  returns=[i for i in range(start+1,end)if lines[i].lstrip().startswith('ret ')]
  if len(returns)!=len(f['returns']):raise Unsupported('LLVM return count differs from textual body')
  for ri,(line,value)in enumerate(zip(returns,f['returns'])):
   original=lines[line].lstrip();stem='ret '+f['return_type']+' '+value
   if not original.startswith(stem):raise Unsupported('Apple return spelling differs from verified LLVM plan')
   tail=original[len(stem):].rstrip('\n');n=lambda field:'%'+prefix+'.'+str(ordinal)+'.'+str(ri)+'.'+field
   emit=[];position=value
   if f['aggregate']:
    emit.append(f"  {n('position')} = extractvalue {f['return_type']} {value}, {f['position_slot']}\n");position=n('position')
   emit += [f"  {n('z')} = extractelement <4 x float> {position}, i32 2\n",f"  {n('w')} = extractelement <4 x float> {position}, i32 3\n",f"  {n('sum')} = fadd float {n('z')}, {n('w')}\n",f"  {n('half')} = fmul float {n('sum')}, 5.000000e-01\n",f"  {n('normalized')} = insertelement <4 x float> {position}, float {n('half')}, i32 2\n"]
   result=n('normalized')
   if f['aggregate']:
    emit.append(f"  {n('result')} = insertvalue {f['return_type']} {value}, <4 x float> {result}, {f['position_slot']}\n");result=n('result')
   emit.append(f"  ret {f['return_type']} {result}{tail}\n")
   if line in edits:raise Unsupported('overlapping vertex plans')
   edits[line]=''.join(emit)
  header=lines[start].rstrip('\n');marked_headers[start]=header[:-1]+'"'+MARKER+'"="1" {\n'
 return ''.join(marked_headers.get(i,edits.get(i,l))for i,l in enumerate(lines))
def lower(source,destination,tool=None):
 b=Path(source).read_bytes();plan=get_plan(source,tool);text=b.decode('utf-8');changed=apply(text,plan);Path(destination).write_bytes(changed.encode());after=get_plan(destination,tool)
 if after['changed']:raise Unsupported('lowering is not idempotent')
 if apply(changed,after)!=changed:raise Unsupported('second lowering changes bytes')
 return dict(schema=1,source_ir_sha256=sha(b),output_ir_sha256=sha(changed.encode()),changed=changed!=text,profile=dict(schema=1,gl_clip_zero_to_one=plan['gl_clip_zero_to_one'],vertex_functions=[x['name']for x in plan['functions']],viewport_contract="near'=2*rawNear-rawFar;far'=rawFar" if plan['gl_clip_zero_to_one']else None),plan=plan)

if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('source',type=Path);p.add_argument('output',type=Path);p.add_argument('--report',type=Path,required=True);a=p.parse_args();r=lower(a.source,a.output);a.report.write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r))
