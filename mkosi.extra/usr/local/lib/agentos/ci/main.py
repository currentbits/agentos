"""agentos-ci entry point (/usr/local/bin/agentos-ci runs this with the AgentOS venv's python)."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from agentos_ci.cli import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main())
