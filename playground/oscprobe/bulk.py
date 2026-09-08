import sys, time
o = sys.stdout.buffer
chunk = b"A" * 65536
for _ in range(128):   # 8MB
    o.write(chunk)
o.flush()
time.sleep(0.5)
