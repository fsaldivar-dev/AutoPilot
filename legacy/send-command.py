#!/usr/bin/env python3
"""
AutoApp CLI - Control the iOS Simulator from terminal.

Usage:
    python3 send-command.py ping
    python3 send-command.py tree
    python3 send-command.py search "Login"
    python3 send-command.py launch com.apple.Preferences
    python3 send-command.py target com.apple.Preferences
    python3 send-command.py tap "General"
    python3 send-command.py type "search_field" "Hello"
    python3 send-command.py swipe up
    python3 send-command.py exists "some_button"
    python3 send-command.py screenshot output.png
    python3 send-command.py getAttribute "some_label" label
"""

import socket
import json
import struct
import sys
import base64

SOCKET_PATH = "/tmp/autoapp.sock"

def send(cmd, args=None):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(SOCKET_PATH)
    except FileNotFoundError:
        print("ERROR: Runner not started. Run ./scripts/start-runner.sh first")
        sys.exit(1)
    except ConnectionRefusedError:
        print("ERROR: Runner not responding. Restart with ./scripts/start-runner.sh")
        sys.exit(1)

    msg = json.dumps({"id": 1, "cmd": cmd, "args": args or {}}).encode()
    sock.sendall(struct.pack(">I", len(msg)) + msg)

    length_data = sock.recv(4)
    length = struct.unpack(">I", length_data)[0]

    response = b""
    while len(response) < length:
        chunk = sock.recv(min(4096, length - len(response)))
        if not chunk:
            break
        response += chunk

    sock.close()
    return json.loads(response.decode())

def print_tree(elements, indent=0):
    for el in elements:
        prefix = "  " * indent
        t = el.get("type", "?")
        label = el.get("label", "")
        ident = el.get("identifier", "")
        frame = el.get("frame", {})

        line = f"{prefix}{t}"
        if label:
            line += f'  "{label}"'
        if ident:
            line += f"  id={ident}"
        if frame:
            line += f"  [{frame.get('x',0)},{frame.get('y',0)} {frame.get('width',0)}x{frame.get('height',0)}]"

        print(line)
        print_tree(el.get("children", []), indent + 1)

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    cmd = sys.argv[1]
    args_list = sys.argv[2:]

    if cmd == "ping":
        r = send("ping")
        print(f"PONG! ({r.get('time', '?')}ms)")

    elif cmd == "tree":
        r = send("tree")
        if r.get("ok"):
            print_tree(r.get("data", []))
        else:
            print("Error:", r.get("error"))

    elif cmd == "search":
        r = send("search", {"query": args_list[0] if args_list else ""})
        if r.get("ok"):
            data = r.get("data", [])
            if not data:
                print("No elements found")
            for el in data:
                ident = el.get("identifier", "")
                label = el.get("label", "")
                print(f'  {el["type"]}  "{label}"  id={ident}')
        else:
            print("Error:", r.get("error"))

    elif cmd == "launch":
        bundle_id = args_list[0]
        r = send("launch", {"bundleId": bundle_id})
        if r.get("ok"):
            print(f"Launched {bundle_id} (target switched)")
        else:
            print("Error:", r.get("error"))

    elif cmd == "target":
        if args_list:
            r = send("target", {"bundleId": args_list[0]})
            if r.get("ok"):
                print(f"Target: {args_list[0]}")
        else:
            r = send("currentTarget")
            if r.get("ok"):
                print(f"Current target: {r.get('bundleId')}")

    elif cmd == "tap":
        r = send("tap", {"target": args_list[0]})
        if r.get("ok"):
            print(f"Tapped '{args_list[0]}' ({r.get('time')}ms)")
        else:
            print("Error:", r.get("error"))

    elif cmd == "doubleTap":
        r = send("doubleTap", {"target": args_list[0]})
        if r.get("ok"):
            print(f"Double tapped '{args_list[0]}' ({r.get('time')}ms)")
        else:
            print("Error:", r.get("error"))

    elif cmd == "longPress":
        target = args_list[0]
        duration = float(args_list[1]) if len(args_list) > 1 else 1.0
        r = send("longPress", {"target": target, "duration": duration})
        if r.get("ok"):
            print(f"Long pressed '{target}' for {duration}s ({r.get('time')}ms)")
        else:
            print("Error:", r.get("error"))

    elif cmd == "type":
        target = args_list[0] if len(args_list) > 1 else None
        text = args_list[-1]
        payload = {"text": text}
        if target and len(args_list) > 1:
            payload["target"] = target
        r = send("type", payload)
        if r.get("ok"):
            print(f"Typed '{text}' ({r.get('time')}ms)")
        else:
            print("Error:", r.get("error"))

    elif cmd == "swipe":
        direction = args_list[0]
        target = args_list[1] if len(args_list) > 1 else None
        payload = {"direction": direction}
        if target:
            payload["target"] = target
        r = send("swipe", payload)
        if r.get("ok"):
            print(f"Swiped {direction} ({r.get('time')}ms)")
        else:
            print("Error:", r.get("error"))

    elif cmd == "exists":
        r = send("exists", {"target": args_list[0]})
        if r.get("ok"):
            found = r.get("exists", False)
            print(f"{'YES' if found else 'NO'} ({r.get('time')}ms)")

    elif cmd == "waitFor":
        target = args_list[0]
        timeout = float(args_list[1]) if len(args_list) > 1 else 10.0
        r = send("waitFor", {"target": target, "timeout": timeout})
        if r.get("ok"):
            print(f"Found '{target}' ({r.get('time')}ms)")
        else:
            print("Error:", r.get("error"))

    elif cmd == "getAttribute":
        r = send("getAttribute", {"target": args_list[0], "attribute": args_list[1]})
        if r.get("ok"):
            print(f"{args_list[1]}: {r.get('value')}")
        else:
            print("Error:", r.get("error"))

    elif cmd == "screenshot":
        filename = args_list[0] if args_list else "screenshot.png"
        r = send("screenshot")
        if r.get("ok"):
            img_data = base64.b64decode(r["data"])
            with open(filename, "wb") as f:
                f.write(img_data)
            print(f"Saved: {filename} ({len(img_data) // 1024}KB)")
        else:
            print("Error:", r.get("error"))

    elif cmd == "terminate":
        r = send("terminate", {"bundleId": args_list[0]})
        if r.get("ok"):
            print(f"Terminated {args_list[0]}")

    else:
        print(f"Unknown command: {cmd}")
        print("Commands: ping, tree, search, launch, target, tap, doubleTap, longPress, type, swipe, exists, waitFor, getAttribute, screenshot, terminate")
        sys.exit(1)

if __name__ == "__main__":
    main()
