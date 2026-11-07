#!/usr/bin/env python3
"""
生成 wfb-ng 密钥对（drone = 机载 TX, gs = 地面 RX）。

与 wfb-ng 的 src/keygen.c 完全等价，但不需要 libsodium：
  drone.key = drone_secret(32B) || gs_public(32B)
  gs.key    = gs_secret(32B)    || drone_public(32B)

libsodium 的 crypto_box_keypair() 先用 randombytes 取 32 字节原样存为
secret key，再在 crypto_scalarmult_base() 内部做 clamp 求公钥。
这里同样：库存原始随机 32 字节，x25519() 内部 clamp，结果一致。

本脚本末尾会做三方自检：
  1. X25519 已知测试向量（RFC 7748 §5.2）
  2. DH(drone_sk, gs_pk) == DH(gs_sk, drone_pk)   —— 链路能通的前提
  3. 落盘文件长度与内容一致性

用法:  python gen-keys.py [输出目录]
"""

import hashlib
import os
import sys

P = 2 ** 255 - 19
A24 = 121665
BASE_U = (9).to_bytes(32, "little")


def _decode_u(b: bytes) -> int:
    n = int.from_bytes(b, "little")
    n &= (1 << 255) - 1          # 丢掉最高位，RFC 7748
    return n % P


def _decode_scalar(b: bytes) -> int:
    n = bytearray(b)
    n[0] &= 248                  # clamp
    n[31] &= 127
    n[31] |= 64
    return int.from_bytes(bytes(n), "little")


def x25519(k: bytes, u: bytes) -> bytes:
    """RFC 7748 X25519，返回 32 字节小端 u 坐标。"""
    if len(k) != 32 or len(u) != 32:
        raise ValueError("x25519 inputs must be 32 bytes")
    scalar = _decode_scalar(k)
    x1 = _decode_u(u)
    x2, z2, x3, z3 = 1, 0, x1, 1
    swap = 0
    for t in range(254, -1, -1):
        kt = (scalar >> t) & 1
        swap ^= kt
        if swap:
            x2, x3 = x3, x2
            z2, z3 = z3, z2
        swap = kt
        a = (x2 + z2) % P
        aa = a * a % P
        b = (x2 - z2) % P
        bb = b * b % P
        e = (aa - bb) % P
        c = (x3 + z3) % P
        d = (x3 - z3) % P
        da = d * a % P
        cb = c * b % P
        x3 = (da + cb) % P
        x3 = x3 * x3 % P
        z3 = (da - cb) % P
        z3 = x1 * z3 * z3 % P
        x2 = aa * bb % P
        z2 = e * (aa + A24 * e) % P
    if swap:
        x2, x3 = x3, x2
        z2, z3 = z3, z2
    return (x2 * pow(z2, P - 2, P) % P).to_bytes(32, "little")


def keypair() -> tuple:
    """等价于 libsodium crypto_box_keypair()。"""
    sk = os.urandom(32)          # 原样保存，未 clamp
    pk = x25519(sk, BASE_U)      # 内部 clamp
    return sk, pk


def fingerprint(pk: bytes) -> str:
    """公钥指纹，给人工核对用（不可逆，可公开）。"""
    h = hashlib.sha256(pk).hexdigest()
    return ":".join(h[i:i + 4] for i in range(0, 16, 4))


def selftest() -> None:
    # RFC 7748 §5.2 向量 1
    k = bytes.fromhex(
        "a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4")
    u = bytes.fromhex(
        "e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c")
    want = bytes.fromhex(
        "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552")
    got = x25519(k, u)
    assert got == want, f"RFC7748 vector 1 FAIL\n got={got.hex()}\nwant={want.hex()}"

    # RFC 7748 §6.1 Alice/Bob 共享密钥
    a_sk = bytes.fromhex(
        "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
    b_sk = bytes.fromhex(
        "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
    a_pk, b_pk = x25519(a_sk, BASE_U), x25519(b_sk, BASE_U)
    assert x25519(a_sk, b_pk) == x25519(b_sk, a_pk), "ECDH symmetry FAIL"
    assert (x25519(a_sk, b_pk).hex() ==
            "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"), \
        "RFC7748 §6.1 shared secret FAIL"
    print("[selftest] RFC 7748 vectors + ECDH symmetry: OK")


def main() -> int:
    # 默认写到本脚本所在的目录，而不是当前工作目录。
    # 原先默认 "." ：从仓库根目录运行时会把 drone.key / gs.key / PUBKEYS.txt
    # 散在根目录 —— 而 .gitignore 里写的是 keys/gs.key，那份散落的 gs.key
    # 不受保护，publish.sh 的 `git add -A` 会把它一起提交。
    out = (sys.argv[1] if len(sys.argv) > 1
           else os.path.dirname(os.path.abspath(__file__)))
    os.makedirs(out, exist_ok=True)

    selftest()

    drone_sk, drone_pk = keypair()
    gs_sk, gs_pk = keypair()

    assert x25519(drone_sk, gs_pk) == x25519(gs_sk, drone_pk), \
        "session key mismatch — keypair unusable"

    drone_key = drone_sk + gs_pk        # 机载用：自己私钥 + 地面公钥
    gs_key = gs_sk + drone_pk           # 地面用：自己私钥 + 机载公钥

    assert len(drone_key) == 64 and len(gs_key) == 64

    for name, blob in (("drone.key", drone_key), ("gs.key", gs_key)):
        path = os.path.join(out, name)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(blob)
        os.chmod(path, 0o600)
        print(f"[write] {path}  {len(blob)} bytes  0600")

    report = os.path.join(out, "PUBKEYS.txt")
    with open(report, "w", encoding="utf-8") as f:
        f.write("# wfb-ng 密钥指纹（仅公钥，可安全分享/用于核对）\n")
        f.write("# 私钥不会出现在本文件中\n\n")
        f.write(f"drone pubkey : {drone_pk.hex()}\n")
        f.write(f"drone fp     : {fingerprint(drone_pk)}\n")
        f.write(f"gs    pubkey : {gs_pk.hex()}\n")
        f.write(f"gs    fp     : {fingerprint(gs_pk)}\n")
        f.write(f"\nsession key  : {x25519(drone_sk, gs_pk).hex()}\n")
        f.write("（session key 由 wfb_tx 每会话重新协商，此处仅作一致性证明）\n")
    print(f"[write] {report}")

    print("\ndrone fp:", fingerprint(drone_pk))
    print("gs    fp:", fingerprint(gs_pk))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
