"""Actual iOS Simulator UI tests; viewport fixtures are not chip emulation."""
from pathlib import Path
import argparse,json,os,re,subprocess,threading

def simulator_pairs(metadata, profile, duo_canvas=False):
    """Prefer the requested model across all runtimes, including model-only runtimes."""
    runtimes=sorted((r for r in metadata['runtimes'] if r.get('isAvailable') and r.get('name','').startswith('iOS ')),
                    key=lambda r:tuple(map(int,r['version'].split('.'))),reverse=True)
    seen=set();pairs=[]
    for preferred in [True,False]:
        for runtime in runtimes:
            supported=runtime.get('supportedDeviceTypes')
            allowed={d['identifier'] if isinstance(d,dict) else d for d in supported} if supported else None
            choices=[]
            for device in metadata['devicetypes']:
                if allowed is not None and device['identifier'] not in allowed:continue
                large='iPad Pro' in device['name'] and ('13-inch' in device['name'] or '12.9-inch' in device['name'])
                if duo_canvas and not large:continue
                wanted='duo' in device['name'].lower() if profile=='duo-unfolded' and not duo_canvas else large and 'M4' in device['name']
                if (wanted if preferred else large):choices.append(device)
            for device in sorted(choices,key=lambda d:('M4' in d['name'],'16GB' in d['name'],d['name']),reverse=True):
                key=(runtime['identifier'],device['identifier'])
                if key not in seen:seen.add(key);pairs.append((runtime,device))
    return pairs

parser=argparse.ArgumentParser()
parser.add_argument('--profile',choices=['duo-unfolded','m4-13'],required=True)
parser.add_argument('--duo-layout-canvas',action='store_true',help='Run the full unfolded viewport test on a large canvas; never claim native Duo validation')
args=parser.parse_args()
if args.duo_layout_canvas and args.profile!='duo-unfolded':parser.error('The canvas alternative is only for the Duo viewport')
root=Path(__file__).resolve().parents[1]
folder=root/'tests/gamepad-preview';artifacts=root/'preview-artifacts';artifacts.mkdir(exist_ok=True)
viewport=(951,669) if args.profile=='duo-unfolded' else (1376,1032)
def output(*cmd):return subprocess.check_output(cmd,text=True,timeout=60)
def diagnostic(label,command):
    # Optional I/O metadata must not prevent the actual app/UI checks.
    try:
        result=subprocess.run(command,capture_output=True,text=True,timeout=15)
        details=f'exit={result.returncode}\n'+result.stdout+result.stderr
    except subprocess.TimeoutExpired:
        details='Optional CoreSimulator diagnostic timed out after 15 seconds\n'
    (artifacts/(label+'.txt')).write_text(details)

metadata=json.loads(output('xcrun','simctl','list','--json'))
(artifacts/'simulator-inventory.json').write_text(json.dumps(metadata,indent=2)+'\n')
runtimes=[r for r in metadata['runtimes'] if r.get('isAvailable') and r.get('name','').startswith('iOS ')]
if not runtimes:raise SystemExit('No installed iOS Simulator runtime; no device test is claimed')
# Device types can be installed by an SDK but unsupported by a particular runtime.
# Try the newest runtime first, preferring the requested model, then a large canvas.
# Record failed combinations instead of claiming the requested device booted.
attempts=[];udid=None
for runtime,device in simulator_pairs(metadata,args.profile,args.duo_layout_canvas):
 created=subprocess.run(['xcrun','simctl','create','Henge-'+args.profile,device['identifier'],runtime['identifier']],capture_output=True,text=True,timeout=60)
 attempts.append(dict(device=device['name'],runtime=runtime['name'],runtime_identifier=runtime['identifier'],status=created.returncode,error=created.stderr.strip()))
 (artifacts/'simulator-selection.json').write_text(json.dumps(attempts,indent=2)+'\n')
 if created.returncode==0:udid=created.stdout.strip();break
if not udid:raise SystemExit('No compatible installed iOS runtime and large Simulator canvas; see simulator-selection.json')
report=dict(source=os.environ.get('GITHUB_SHA'),profile=args.profile,requested_viewport=viewport,
            simulator_device=device['name'],runtime=runtime['name'],xcode=output('xcodebuild','-version').strip(),
            host_model=output('sysctl','-n','hw.model').strip(),host_cores=output('sysctl','-n','hw.logicalcpu').strip(),
            scope='Production controller UI/input checks only. A20/M4 CPU, GPU, core placement and thermals are not emulated.',
            duo_unfolded_requested=args.profile=='duo-unfolded',fallback_canvas=('duo' not in device['name'].lower()) if args.profile=='duo-unfolded' else ('M4' not in device['name']))
report['validation_mode']='unfolded-viewport-fixture' if args.duo_layout_canvas else 'native-model-preferred'
if args.duo_layout_canvas:
 report['native_duo_validation']='blocked: dedicated iOS 27.2 runtime SpringBoard/test-runner launch failure; public display power RPC also times out'
 report['native_duo_failure_run']=43158389557
 report['native_duo_failure_job']=130983663525
 report['native_duo_failure_artifact']=13917861161
(artifacts/'environment.json').write_text(json.dumps(report,indent=2)+'\n')
native_duo=args.profile=='duo-unfolded' and 'duo' in device['name'].lower()
(folder/'Fixture.swift').write_text('import Foundation\nimport CoreGraphics\nenum PreviewFixture { static let profile='+json.dumps(args.profile)+'; static let viewport=CGSize(width:'+str(viewport[0])+',height:'+str(viewport[1])+'); static let isNativeDuo='+str(native_duo).lower()+' }\n')
stop_fold=threading.Event();fold_errors=[]
def unfold_after_ui_launch():
 configuration=[]
 try:
  while not stop_fold.is_set():
   log=artifacts/'xcodebuild.log'
   text=''
   if log.exists():
    with log.open('rb') as data:
     data.seek(max(0,log.stat().st_size-65536));text=data.read().decode(errors='replace')
   if 'HENGE_DUO_UNFOLD_REQUIRED' in text:break
   stop_fold.wait(1) # CI host only; no timer or worker is added to Henge
  else:return
  for display,power in [('3','on'),('1','off')]:
   command=['xcrun','simctl','io',udid,'screenConfig','--display='+display,'power',power]
   change=subprocess.run(command,capture_output=True,text=True,timeout=60)
   configuration.append(dict(display=display,power=power,status=change.returncode,output=change.stdout+change.stderr))
   (artifacts/'unfolded-configuration.json').write_text(json.dumps(configuration,indent=2)+'\n')
   if change.returncode:raise RuntimeError('Duo screen configuration failed')
  report['duo_inner_display']='3';report['duo_outer_power']='off'
  (artifacts/'environment.json').write_text(json.dumps(report,indent=2)+'\n')
  diagnostic('displays-unfolded',['xcrun','simctl','io',udid,'enumerate'])
 except Exception as error:
  fold_errors.append(str(error))
  (artifacts/'unfolded-error.txt').write_text(str(error))
try:
 subprocess.run(['xcrun','simctl','boot',udid],check=True,timeout=240)
 subprocess.run(['xcrun','simctl','bootstatus',udid,'-b'],check=True,timeout=480)
 subprocess.run(['xcodegen','generate'],cwd=folder,check=True)
 command=['xcodebuild','-project',str(folder/'HengeGamepadPreview.xcodeproj'),'-scheme','GamepadPreview',
          '-destination','id='+udid,'-derivedDataPath',str(root/'build/gamepad-preview'),
          '-resultBundlePath',str(artifacts/'GamepadPreview.xcresult'),'-parallel-testing-enabled','NO',
          '-test-timeouts-enabled','YES','-default-test-execution-time-allowance','480',
          '-maximum-test-execution-time-allowance','600','CODE_SIGNING_ALLOWED=NO','test']
 timed_out=False;fold_thread=None
 if native_duo:
  fold_thread=threading.Thread(target=unfold_after_ui_launch,daemon=True);fold_thread.start()
 with (artifacts/'xcodebuild.log').open('w') as log:
  try: result=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,text=True,timeout=1500,env={**os.environ,'NSUnbufferedIO':'YES'});status=result.returncode
  except subprocess.TimeoutExpired:timed_out=True;status=124
 stop_fold.set()
 if fold_thread:fold_thread.join(timeout=75)
 if native_duo and status==0:
  # XCTest's required window assertion is authoritative even if an already
  # satisfied state did not need a power request. Preserve any RPC warning.
  report['native_duo_unfolded_window_verified']=True
  if fold_errors:report['optional_display_request_warning']=fold_errors
 print('\n'.join((artifacts/'xcodebuild.log').read_text().splitlines()[-35:]))
 if timed_out:print('xcodebuild exceeded the 25-minute preview limit; retained log and failure state')
 if status:diagnostic('failure-screenshot',['xcrun','simctl','io',udid,'screenshot','--display=1',str(artifacts/'failure-state.png')])
 diagnostic('active-display-screenshot',['xcrun','simctl','io',udid,'screenshot','--display='+('3' if native_duo else '1'),str(artifacts/'active-display.png')])
 # Preserve exact UIKit window pixels too: recent Simulator XCTest images can
 # carry a rotation/crop inconsistent with their correctly reported AX bounds.
 try:
  container=Path(output('xcrun','simctl','get_app_container',udid,'com.henge.gamepadpreview','data').strip())
  proofs=container/'Documents/ControlsWindowProof'
  if proofs.exists():
   import shutil
   shutil.copytree(proofs,artifacts/'ui-window-proof',dirs_exist_ok=True)
  report['direct_window_captures']=len(list((artifacts/'ui-window-proof').glob('*.png')))
  if status==0 and report['direct_window_captures']<5:
   raise RuntimeError('Successful UI test lacks direct UIKit window captures')
 except Exception as error:
  (artifacts/'window-proof-error.txt').write_text(str(error))
  if status==0:raise
 # Kept XCTest screenshot attachments remain available even after a UI failure.
 subprocess.run(['xcrun','xcresulttool','export','attachments','--path',str(artifacts/'GamepadPreview.xcresult'),'--output-path',str(artifacts/'screenshots')],check=False)
 if status:raise SystemExit(status)
 if not list((artifacts/'screenshots').rglob('*.png')):raise SystemExit('XCTest passed but screenshot export is missing; preview verification incomplete')
 report['ui_tests']='passed';(artifacts/'environment.json').write_text(json.dumps(report,indent=2)+'\n')
finally:
 stop_fold.set()
 diagnostic('cleanup-shutdown',['xcrun','simctl','shutdown',udid])
 diagnostic('cleanup-delete',['xcrun','simctl','delete',udid])
