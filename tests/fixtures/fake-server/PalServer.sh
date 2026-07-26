#!/usr/bin/env bash
# Test fixture: stand-in for the real PalServer.sh. Execs the "binary" directly.
exec ./Pal/Binaries/Linux/PalServer-Linux-Shipping Pal "$@"
