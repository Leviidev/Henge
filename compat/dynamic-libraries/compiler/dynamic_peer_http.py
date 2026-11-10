#!/usr/bin/env python3
"""Opt-in authenticated closure compiler endpoint. Not started by preparation.
Default bind is localhost. Root owns any forwarding/listening policy and lifecycle.
"""
import argparse,concurrent.futures,hmac,json,re,threading,time
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
from pathlib import Path
from compile_requests import compile_one,RECIPE
from closure import sha

def server(bind,port,token,exchange,work):
 requests=exchange/'requests';ready=exchange/'ready';requests.mkdir(parents=True,exist_ok=True);ready.mkdir(parents=True,exist_ok=True)
 pool=concurrent.futures.ThreadPoolExecutor(max_workers=1);pending=set();lock=threading.Lock()
 def compile_job(path):
  try:r=compile_one(path,ready,work)
  except Exception as e:
   r=dict(schema=1,recipe=RECIPE,request_sha256=path.stem,status='rejected',error=str(e));tmp=ready/(path.stem+'.json.tmp');tmp.write_text(json.dumps(r));tmp.replace(ready/(path.stem+'.json'))
  finally:
   with lock:pending.discard(path.stem)
  print(json.dumps(dict(event='compiled',time=time.time(),**r)),flush=True)
 class Handler(BaseHTTPRequestHandler):
  def setup(self):super().setup();self.connection.settimeout(10)
  def auth(self):
   if not hmac.compare_digest(self.headers.get('Authorization',''),'Bearer '+token):self.send_error(401);return False
   return True
  def send(self,code,data,kind='application/json'):
   self.send_response(code);self.send_header('Content-Type',kind);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
  def do_POST(self):
   if not self.auth():return
   m=re.fullmatch(r'/v1/requests/([0-9a-f]{64})',self.path)
   if not m:self.send_error(404);return
   try:n=int(self.headers.get('Content-Length','0'))
   except ValueError:self.send_error(400);return
   if not 0<n<=24*1024*1024:self.send_error(413);return
   data=self.rfile.read(n);key=m[1]
   if len(data)!=n or sha(data)!=key:self.send_error(400,'request digest mismatch');return
   try:r=json.loads(data)
   except ValueError:self.send_error(400);return
   if r.get('recipe')!=RECIPE:self.send_error(409,'recipe mismatch');return
   with lock:
    if key in pending or (ready/(key+'.json')).exists():self.send(200,b'{"status":"known"}');return
    if len(pending)>=16:self.send_error(503);return
    temp=requests/(key+'.tmp');temp.write_bytes(data);path=requests/(key+'.json');temp.replace(path);pending.add(key);pool.submit(compile_job,path)
   self.send(202,b'{"status":"queued"}')
  def do_GET(self):
   if not self.auth():return
   m=re.fullmatch(r'/v1/ready/([0-9a-f]{64})\.(json|metallib)',self.path)
   if not m:self.send_error(404);return
   p=ready/(m[1]+'.'+m[2])
   if not p.is_file():self.send_error(404);return
   self.send(200,p.read_bytes(),'application/json' if m[2]=='json' else 'application/octet-stream')
 http=ThreadingHTTPServer((bind,port),Handler);return http,pool
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--bind',default='127.0.0.1');p.add_argument('--port',type=int,required=True);p.add_argument('--token-file',type=Path,required=True);p.add_argument('--exchange',type=Path,required=True);p.add_argument('--work',type=Path,required=True);p.add_argument('--seconds',type=int,default=1800);a=p.parse_args();token=a.token_file.read_text().strip()
 if not re.fullmatch(r'[A-Za-z0-9_-]{32,128}',token):p.error('token must contain32–128letters/digits/underscore/dash')
 http,pool=server(a.bind,a.port,token,a.exchange,a.work);timer=threading.Timer(max(1,min(a.seconds,7200)),http.shutdown);timer.daemon=True;timer.start();print(json.dumps({'event':'listening','bind':a.bind,'port':http.server_port,'recipe':RECIPE}),flush=True)
 try:http.serve_forever()
 except KeyboardInterrupt:pass
 finally:timer.cancel();http.server_close();pool.shutdown(wait=True)
