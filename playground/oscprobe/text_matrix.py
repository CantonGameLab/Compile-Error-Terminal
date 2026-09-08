import sys, time
o = sys.stdout.buffer
for kb in (64, 256, 1024):
    o.write(b"T" * (kb * 1024))
    o.write(("TEXT%d-DONE\r\n" % kb).encode())
    o.flush()
    time.sleep(0.8)
time.sleep(0.5)
