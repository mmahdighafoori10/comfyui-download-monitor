import argparse
import http.server
from pathlib import Path


class RangeRequestHandler(http.server.BaseHTTPRequestHandler):
    source_path: Path
    log_path: Path

    def do_GET(self) -> None:
        data_length = self.source_path.stat().st_size
        range_header = self.headers.get("Range", "")
        start = 0
        status = 200

        if range_header.startswith("bytes=") and range_header.endswith("-"):
            start = int(range_header[6:-1])
            status = 206

        with self.log_path.open("a", encoding="utf-8") as log_file:
            log_file.write(range_header + "\n")

        self.send_response(status)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(data_length - start))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{data_length - 1}/{data_length}")
        self.end_headers()

        with self.source_path.open("rb") as source_file:
            source_file.seek(start)
            while True:
                chunk = source_file.read(256 * 1024)
                if not chunk:
                    break
                self.wfile.write(chunk)

    def log_message(self, format_string: str, *args: object) -> None:
        return


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--log", required=True, type=Path)
    args = parser.parse_args()

    RangeRequestHandler.source_path = args.source
    RangeRequestHandler.log_path = args.log
    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), RangeRequestHandler)
    server.serve_forever()


if __name__ == "__main__":
    main()
