"""strata/ctl 的引导脚本（dev 与便携包通用）。

为什么需要它：便携包里的 CPython 带 `python311._pth`，那会把 sys.path 固定住，
`python -m strata.ctl` 找不到 `strata` 包。这里手动把脚本所在目录塞进 sys.path，
再交给 `strata.ctl.__main__`，两种布局都能跑。

用法（与 -m 完全相同）：
    python strata-ctl.py plan    --ini-in in.ini --ini-out state.ini
    python strata-ctl.py observe --engine-log … --ini-out state.ini
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from strata.ctl.__main__ import main   # noqa: E402  (必须在 sys.path 调整之后)

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
