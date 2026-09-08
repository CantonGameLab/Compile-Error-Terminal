import sys, time
o = sys.stdout.buffer
o.write(b"\x1b[31mSGR-RED-TEXT\x1b[0m\r\n")
o.write(b"\x1b]0;OSC-TITLE-TEST\x07")
o.write(b"OSC-DONE\r\n")
o.write(b"\x1b_Pq\"1;1;1;1DCS-TEST\x1b\\")
o.write(b"DCS-DONE\r\n")
o.write(b"\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\")
o.write(b"APC-DONE\r\n")
o.flush()
time.sleep(1.0)
