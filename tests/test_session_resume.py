"""Run the production Foundation coordinator/identity with deterministic native boundaries.
Real VM, snapshot, file, cancellation and graphics lifetime tests run separately.
"""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='henge-resume-') as directory:
    binary=Path(directory)/'check'
    subprocess.run(['swiftc','-parse-as-library','-swift-version','5',str(root/'ios/Henge/ResumeCoordinator.swift'),str(root/'ios/Henge/ResumeIdentity.swift'),str(root/'tests/test_resume_coordinator.swift'),'-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True,timeout=30)
