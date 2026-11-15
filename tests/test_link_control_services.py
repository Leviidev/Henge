"""Run actual production Link service class bodies on macOS over real TLS.
Only unused UIKit import is removed; native VM/gamepad sink is a boundary spy.
"""
from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[1]
out=root/'build/link';out.mkdir(parents=True,exist_ok=True)
source=(root/'ios/Henge/Link/LinkService.swift').read_text()
assert source.count('import UIKit\n')==1
adapted=out/'LinkServiceMac.swift'
adapted.write_text(source.replace('import UIKit\n',''))
subprocess.run(['xcrun','--sdk','macosx','clang','-fblocks','-std=c11','-Wall','-Wextra','-Werror','-Itests','-c','tests/link_control_service_fixture.c','-o',str(out/'control_fixture.o')],cwd=root,check=True)
files=['ios/Henge/Controls/GamepadState.swift']+[f'ios/Henge/Link/{name}.swift' for name in ['LinkProtocol','LinkReconnectPolicy','LinkPairing','LinkTransport','LinkVideo','LinkFlowControl','LinkDecodeWorker']]
subprocess.run(['swiftc','-parse-as-library','-swift-version','5','-import-objc-header','tests/link_control_service_fixture.h',*files,str(adapted),'tests/test_link_control_services.swift',str(out/'control_fixture.o'),'-framework','Network','-framework','Security','-framework','Metal','-framework','CoreMedia','-framework','CoreVideo','-framework','VideoToolbox','-o',str(out/'control_services')],cwd=root,check=True)
subprocess.run([str(out/'control_services')],cwd=root,check=True,timeout=80)
