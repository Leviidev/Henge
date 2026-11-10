#!/usr/bin/env python3
"""Compare sampled iPad VLC screenshots with the closest source video frame.

ROI and exclusion mask are explicit for this fixed UI layout. Reports every
capture including launches/closed windows; a large error is not silently
excluded as a non-video frame. JPEG/resizing make this a display regression
metric, not a byte-exact GPU oracle. For untagged fixtures, pass the matrix the
player actually selects (VLC 3 defaults unmarked HD input to BT.709).
"""
import argparse,json,subprocess
from pathlib import Path
import numpy as np
from PIL import Image

def reference(path,matrix):
    raw=subprocess.check_output(['ffmpeg','-hide_banner','-loglevel','error','-i',str(path),
      '-an','-vf',f'scale=80:45:in_color_matrix={matrix}:flags=bilinear','-pix_fmt','rgb24','-f','rawvideo','-'])
    return np.frombuffer(raw,dtype=np.uint8).reshape(-1,45,80,3).astype(np.float32)

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('sequence',type=Path);p.add_argument('--media',type=Path,required=True);p.add_argument('--matrix',choices=['bt709','bt601'],required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    mask=np.ones((45,80),bool);mask[:2,:]=False;mask[-2:,:]=False;mask[:,:2]=False;mask[:,-2:]=False
    mask[13:33,46:68]=False # restart warning and its shadow
    mask[:5,:12]=False # tiny burned-in frame counter
    refs={};results=[]
    for item in json.loads((a.sequence/'manifest.json').read_text())['frames']:
        row={**item};path=a.sequence/item['file']
        if not path.exists():results.append(row);continue
        text=item.get('guest_progress','').strip().split('\n')[-1];codec=text.split()[0]
        if codec not in ('h264','hevc','hevc10'):row['comparison']='unknown codec';results.append(row);continue
        if codec not in refs:refs[codec]=reference(a.media/(codec+'.mp4'),a.matrix)[:,mask,:]
        im=Image.open(path).convert('RGB').crop((396,79,801,307)).resize((80,45),Image.Resampling.BILINEAR)
        actual=np.asarray(im,dtype=np.float32)[mask,:];scores=np.mean((refs[codec]-actual)**2,axis=(1,2))**.5
        best=int(np.argmin(scores));row.update(codec=codec,closest_source_frame=best,rmse=float(scores[best]),comparison='compared')
        results.append(row)
    a.output.write_text(json.dumps({'matrix':a.matrix,'roi':[396,79,801,307],'resize':[80,45],'mask':'2px border; x46:68/y13:33 restart dialog; x0:12/y0:5 counter','results':results},indent=2)+'\n')
    print(json.dumps([{'file':r['file'],'codec':r.get('codec'),'source_frame':r.get('closest_source_frame'),'rmse':round(r.get('rmse',0),2)} for r in results]))
if __name__=='__main__':main()
