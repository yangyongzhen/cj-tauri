#!/usr/bin/env python3
"""cj-link 探针对端（Windows 版）：TCP echo + UDP echo。

Linux 的 cj-link-peer.py 还扮演串口 pty，Windows 没有 pty——本机是一条真实存在的
虚拟串口对（VSerial_0/1 = COM1/COM2，已实测互通），串口那头由 link-serial-echo.ps1
用 System.IO.Ports 拿 COM2 扮演，所以这里只管两条网络链路。

用法：python link-peer-win.py <peer-log> [tcp-port] [udp-port]
"""
import socket
import sys
import threading


def log_to(path):
    f = open(path, "w", buffering=1)
    sys.stdout = f
    sys.stderr = f


def tcp_peer(port):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(4)
    print("[tcp-peer] listening on 127.0.0.1:%d" % port, flush=True)

    def handle(conn, addr):
        print("[tcp-peer] client %s:%d connected" % addr, flush=True)
        try:
            while True:
                data = conn.recv(1024)
                if not data:
                    break
                print("[tcp-peer] rx %d bytes, echoing" % len(data), flush=True)
                conn.sendall(data)
        except OSError:
            pass
        finally:
            conn.close()
            print("[tcp-peer] client %s:%d closed" % addr, flush=True)

    while True:
        conn, addr = srv.accept()
        threading.Thread(target=handle, args=(conn, addr), daemon=True).start()


def udp_peer(port):
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    u.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    u.bind(("127.0.0.1", port))
    print("[udp-peer] listening on 127.0.0.1:%d" % port, flush=True)
    while True:
        data, addr = u.recvfrom(4096)
        print("[udp-peer] %d bytes from %s:%d, echoing" % (len(data), addr[0], addr[1]), flush=True)
        u.sendto(data, addr)


def main():
    log_to(sys.argv[1])
    tcp_port = int(sys.argv[2]) if len(sys.argv) > 2 else 15021
    udp_port = int(sys.argv[3]) if len(sys.argv) > 3 else 15022
    threading.Thread(target=udp_peer, args=(udp_port,), daemon=True).start()
    tcp_peer(tcp_port)


if __name__ == "__main__":
    main()
