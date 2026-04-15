#!/usr/bin/env python3

import json
import sys


def main() -> int:
    payload = sys.stdin.read()
    prefix = '--url "'
    start = payload.find(prefix)

    if start == -1:
        sys.stdout.write("HTTP/1.1 400 Bad Request\r\n")
        sys.stdout.write("Content-Type: text/plain\r\n")
        sys.stdout.write("\r\n")
        sys.stdout.write("missing --url")
        return 0

    start += len(prefix)
    end = payload.find('"\n--', start)
    if end == -1:
        end = payload.find('"\n', start)
    response = payload[start:] if end == -1 else payload[start:end]

    sys.stdout.write("HTTP/1.1 200 OK\r\n")
    sys.stdout.write("Content-Type: text/event-stream\r\n")
    sys.stdout.write("\r\n")
    sys.stdout.flush()

    chunk_size = 12
    for index in range(0, len(response), chunk_size):
        chunk = response[index:index + chunk_size]
        sys.stdout.write(
            "data: "
            + json.dumps({"choices": [{"delta": {"content": chunk}}]})
            + "\n\n"
        )
        sys.stdout.flush()

    sys.stdout.write("data: [DONE]\n\n")
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
