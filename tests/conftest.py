import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "src" / "processor"))

os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")
os.environ.setdefault("RESULTS_BUCKET", "test-bucket")
os.environ.setdefault("RESULTS_TABLE", "test-table")
