"""devflow Python 单测公共夹具——scripts/ 入 sys.path（pytest 独立于 shell 套件）"""
import sys
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent.parent / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))
