import sys, time
o = sys.stdout.buffer
chunk = b"B" * 65536
for i in range(32):   # 2MB
    o.write(chunk)
    o.flush()
o.write(b"\r\nTEXT-DONE\r\n")
o.flush()
time.sleep(2.0)
