#!/bin/bash
export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
exec "$(dirname "$0")/safari_sync.py"
