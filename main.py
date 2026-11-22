import sys
import os

backend_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'BACKEND')
if backend_dir not in sys.path:
    sys.path.insert(0, backend_dir)

from BACKEND.main import app
