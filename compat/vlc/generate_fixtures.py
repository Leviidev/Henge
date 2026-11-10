#!/usr/bin/env python3
"""Generate original test pictures/tones; no captured media or Apple shader assets."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True);p.add_argument('--ffmpeg',default='ffmpeg');a=p.parse_args();out=a.output.resolve();out.mkdir(parents=True,exist_ok=False);commands=[]
 def run(args,name):
  command=[a.ffmpeg,'-v','warning']+args+[str(out/name)];commands.append(command)
  with(out/(name+'.generation.log')).open('w')as log:subprocess.run(command,stdout=log,stderr=log,check=True)
 run(['-f','lavfi','-i','testsrc2=size=1280x720:rate=30:duration=10','-f','lavfi','-i','sine=frequency=440:sample_rate=48000:duration=10','-vf','setparams=range=limited:color_primaries=smpte170m:color_trc=smpte170m:colorspace=smpte170m','-c:v','libx264','-preset','fast','-crf','18','-pix_fmt','yuv420p','-color_range','tv','-color_primaries','smpte170m','-color_trc','smpte170m','-colorspace','smpte170m','-c:a','aac','-b:a','128k','-t','10'],'h264-bt601.mp4')
 run(['-i',str(out/'h264-bt601.mp4'),'-vf','colorspace=iall=smpte170m:all=bt709','-c:v','libx264','-preset','fast','-crf','18','-color_range','tv','-colorspace','bt709','-color_trc','bt709','-color_primaries','bt709','-c:a','copy'],'h264-bt709.mp4')
 run(['-i',str(out/'h264-bt709.mp4'),'-t','2','-vf','scale=in_range=tv:out_range=pc,setsar=5/4','-c:v','libx264','-preset','fast','-crf','18','-pix_fmt','yuvj420p','-color_range','pc','-colorspace','bt709','-color_trc','bt709','-color_primaries','bt709','-c:a','copy'],'h264-bt709-full-sar.mp4')
 run(['-f','lavfi','-i','sine=frequency=440:sample_rate=48000:duration=2.003','-f','lavfi','-i','sine=frequency=880:sample_rate=48000:duration=2.003','-filter_complex','[0:a][1:a]amerge=inputs=2[a]','-map','[a]','-c:a','aac','-b:a','192k'],'stereo-2.003s.m4a')
 manifest={'schema':1,'authored':True,'ffmpeg_version':subprocess.check_output([a.ffmpeg,'-version'],text=True).splitlines()[0],'commands':commands,'inputs':{f.name:hashlib.sha256(f.read_bytes()).hexdigest()for f in sorted(out.iterdir())if f.suffix in ['.mp4','.m4a']},'limits':'Source generation is version-bound, not a byte-identical cross-FFmpeg guarantee. Bind generated hashes before testing; exports are not postprocessed.'}
 (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
if __name__=='__main__':main()
