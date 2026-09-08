import base64, os, sys, time
o = sys.stdout.buffer
# ??? 4KB / 16KB / 64KB / 256KB ? OSC ??(?64),??????
for kb in (4, 16, 64, 256):
    payload = base64.b64encode(os.urandom(kb * 1024))
    o.write(b"\x1b]999;" + payload + b"\x07")
    o.write(("MARK%d\r\n" % kb).encode())
    o.flush()
    time.sleep(0.4)
time.sleep(0.5)
