#!/bin/bash
# Prints 1 when the login session's screen is locked, else 0.
python3 - <<'PY'
import ctypes, ctypes.util
cg = ctypes.CDLL(ctypes.util.find_library('CoreGraphics'))
cf = ctypes.CDLL(ctypes.util.find_library('CoreFoundation'))
cg.CGSessionCopyCurrentDictionary.restype = ctypes.c_void_p
cf.CFCopyDescription.restype = ctypes.c_void_p; cf.CFCopyDescription.argtypes = [ctypes.c_void_p]
cf.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
d = cg.CGSessionCopyCurrentDictionary(); s = cf.CFCopyDescription(d)
buf = ctypes.create_string_buffer(8192); cf.CFStringGetCString(s, buf, 8192, 0x08000100)
print(1 if "CGSSessionScreenIsLocked = 1" in buf.value.decode() else 0)
PY
