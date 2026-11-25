"""Local Messages endpoint for the canonical Cogball player in the Docker smoke."""
import json
import sys
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        team = "AZ" if self.headers["X-Coworld-Player-Slot"] == "0" else "CR"
        reply = {"robots": [
            {"id": f"{team}-1", "intent": "hold", "target": [0, 0]},
            {"id": f"{team}-2", "intent": "shoot"},
            {"id": f"{team}-3", "intent": "intercept", "target": [0, 0]},
        ]}
        body = json.dumps({
            "model": request["model"], "stop_reason": "end_turn",
            "content": [{"type": "text", "text": json.dumps(reply)}],
            "usage": {"input_tokens": 12, "output_tokens": 6},
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Softmax-Llm-Call-Id", str(uuid.uuid4()))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", 0), Handler)
    Path(sys.argv[1]).write_text(str(server.server_port))
    server.serve_forever()
