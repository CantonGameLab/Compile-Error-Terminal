import base64, os, sys, time
o = sys.stdout.buffer
for kb in (512, 1024):
    payload = base64.b64encode(os.urandom(kb * 1024))
    o.write(b"\x1b]999;" + payload + b"\x07")
    o.write(("OSC%d-DONE\r\n" % kb).encode())
    o.flush()
    time.sleep(0.8)
time.sleep(0.5)
