#!/usr/bin/env python3
"""Exercise the actual diagnostic method from concurrent presenter/replay callers."""
from pathlib import Path
import re
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / "devices/pvg_metal.m").read_text()
method = re.search(r'- \(void\)complain:\(NSString \*\)what \{.*?\n\}', source, re.S)
assert method, "diagnostic method missing"
program = '''#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
@interface DiagnosticControl : NSObject { @public NSMutableSet *complaints; }
- (void)complain:(NSString *)what;
@end
@implementation DiagnosticControl
METHOD
@end
int main(void) { @autoreleasepool {
    DiagnosticControl *d = [DiagnosticControl new];
    d->complaints = [NSMutableSet new];
    dispatch_apply(16000, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) {
        @autoreleasepool { [d complain:[NSString stringWithFormat:@"control-%zu", i % 32]]; }
    });
    return d->complaints.count == 32 ? 0 : 1;
} }
'''.replace("METHOD", method.group())
with tempfile.TemporaryDirectory(prefix="henge-diagnostics-") as directory:
    root = Path(directory)
    (root / "control.m").write_text(program)
    subprocess.run(["xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-framework", "Foundation",
                    str(root / "control.m"), "-o", str(root / "control")], check=True)
    run = subprocess.run([str(root / "control")], capture_output=True, text=True, timeout=30, check=True)
    lines = run.stderr.splitlines()
    expected = {f"hengevm: pvg-metal: control-{i}" for i in range(32)}
    assert len(lines) == 32 and set(lines) == expected, (len(lines), set(lines))
print("16000 concurrent reports: exactly 32 distinct diagnostics; no GPU work")
