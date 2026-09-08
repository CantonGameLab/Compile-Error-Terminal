# 正宗 kitty 图形协议客户端(kitty 文档 minimal example 的扩展版):
#   case1 分块 PNG 传输+显示(a=T,f=100,m=1/m=0)
#   case2 先传(a=t,f=32 原始 RGBA)后放置(a=p,i=7),验证"传输/显示分离"+ 光标定位
#   case3 o=z 压缩 PNG 传输+显示(zlib 流)
#   case4 a=q 查询:读终端应答并打印(验证应答回路)
# 全部走 stdout → ConPTY → dterm。用法: python send_png.py <png 路径>
import base64, sys, threading, time, zlib

out = sys.stdout.buffer


def flush():
    out.flush()


def apc(ctrl: str, payload: bytes = b""):
    out.write(b"\x1b_G" + ctrl.encode("ascii") + b";" + payload + b"\x1b\\")


def chunked(ctrl_first: str, data: bytes, chunk: int = 4096):
    b64 = base64.standard_b64encode(data)
    parts = [b64[i:i + chunk] for i in range(0, len(b64), chunk)] or [b""]
    for i, p in enumerate(parts):
        more = 0 if i == len(parts) - 1 else 1
        ctrl = f"{ctrl_first},m={more}" if i == 0 else f"m={more}"
        apc(ctrl, p)
    flush()


def cup(row: int, col: int = 1):
    out.write(f"\x1b[{row};{col}H".encode("ascii"))


png_path = sys.argv[1]
png = open(png_path, "rb").read()

# ── case1:分块 PNG,显示在 (1,1)
cup(1, 1)
chunked("a=T,f=100", png)
out.write(b"\r\n")
flush()
time.sleep(0.2)

# ── case2:原始 RGBA 先传后放(80x40 渐变,行 12)
W, H = 80, 40
rgba = bytearray()
for y in range(H):
    for x in range(W):
        rgba += bytes((x * 255 // (W - 1), y * 255 // (H - 1), 128, 255))
chunked("a=t,f=32,s=%d,v=%d,i=7" % (W, H), bytes(rgba))
cup(12, 1)
apc("a=p,i=7")
out.write(b"\r\n")
flush()
time.sleep(0.2)

# ── case3:o=z 压缩 PNG(行 22)
cup(22, 1)
chunked("a=T,f=100,o=z", zlib.compress(png))
out.write(b"\r\n")
flush()

# ── case4:查询 + 读应答(线程读,1s 超时)
apc("i=31,s=1,v=1,a=q,t=d,f=24", b"AAAA")
flush()
reply = [b""]


def reader():
    try:
        reply[0] = sys.stdin.buffer.read1(4096)
    except Exception as e:
        reply[0] = b"(err:%s)" % str(e).encode()


t = threading.Thread(target=reader, daemon=True)
t.start()
t.join(1.0)
out.write(b"\r\nquery reply: " + (reply[0] if reply[0] else b"(none)") + b"\r\n")
flush()
time.sleep(1.5)
