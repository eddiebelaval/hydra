#!/usr/bin/env python3
"""
HYDRA Dashboard Server
Serves the morning dashboard on localhost:7777 and provides a REST API
for goal CRUD (used by the dashboard UI, Telegram, and Claude sessions).

Usage:
    python3 ~/.hydra/dashboard/server.py          # foreground
    python3 ~/.hydra/dashboard/server.py --daemon  # background (launchd)

API:
    GET  /api/data              — full dashboard data (regenerates)
    GET  /api/goals             — all goals
    POST /api/goals             — create goal
    PUT  /api/goals/<id>        — update goal (progress, status, note)
    GET  /api/refresh           — regenerate data.json
"""

import json
import os
import sqlite3
import subprocess
import sys
import uuid
from datetime import datetime
from http.server import HTTPServer, SimpleHTTPRequestHandler
from urllib.parse import urlparse

PORT = 7777
HYDRA_DB = os.path.expanduser("~/.hydra/hydra.db")
DASHBOARD_DIR = os.path.expanduser("~/.hydra/dashboard")
DATA_JSON = os.path.join(DASHBOARD_DIR, "data.json")
GENERATE_SCRIPT = os.path.join(DASHBOARD_DIR, "generate-data.sh")


def get_db():
    conn = sqlite3.connect(HYDRA_DB)
    conn.row_factory = sqlite3.Row
    return conn


def regenerate_data():
    """Run the data generator script and return the JSON."""
    subprocess.run(["bash", GENERATE_SCRIPT], capture_output=True, timeout=30)
    with open(DATA_JSON) as f:
        return json.load(f)


class DashboardHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DASHBOARD_DIR, **kwargs)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/api/data":
            try:
                data = regenerate_data()
                self._json_response(data)
            except Exception as e:
                self._json_response({"error": str(e)}, 500)
            return

        if path == "/api/goals":
            try:
                conn = get_db()
                rows = conn.execute(
                    "SELECT * FROM goals ORDER BY horizon, status, created_at"
                ).fetchall()
                goals = [dict(r) for r in rows]
                conn.close()
                self._json_response(goals)
            except Exception as e:
                self._json_response({"error": str(e)}, 500)
            return

        if path == "/api/refresh":
            try:
                regenerate_data()
                self._json_response({"status": "ok"})
            except Exception as e:
                self._json_response({"error": str(e)}, 500)
            return

        # Serve static files (index.html, data.json, etc.)
        super().do_GET()

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/api/goals":
            try:
                body = self._read_body()
                conn = get_db()
                goal_id = uuid.uuid4().hex[:16]
                conn.execute(
                    """INSERT INTO goals (id, horizon, period, description, category, status, progress)
                       VALUES (?, ?, ?, ?, ?, 'active', 0)""",
                    (
                        goal_id,
                        body["horizon"],
                        body["period"],
                        body["description"],
                        body.get("category", "product"),
                    ),
                )
                conn.commit()

                # Log check-in
                conn.execute(
                    """INSERT INTO goal_checkins (id, goal_id, date, progress, note, source)
                       VALUES (?, ?, date('now'), 0, ?, ?)""",
                    (uuid.uuid4().hex[:16], goal_id, "Goal created", body.get("source", "dashboard")),
                )
                conn.commit()
                conn.close()

                self._json_response({"id": goal_id, "status": "created"}, 201)
            except Exception as e:
                self._json_response({"error": str(e)}, 400)
            return

        self._json_response({"error": "not found"}, 404)

    def do_PUT(self):
        parsed = urlparse(self.path)
        path = parsed.path

        # /api/goals/<id>
        if path.startswith("/api/goals/"):
            goal_id = path.split("/")[-1]
            try:
                body = self._read_body()
                conn = get_db()

                # Build update query dynamically
                updates = []
                params = []
                for field in ["progress", "status", "description", "category", "notes", "target_date"]:
                    if field in body:
                        updates.append(f"{field} = ?")
                        params.append(body[field])

                if not updates:
                    self._json_response({"error": "no fields to update"}, 400)
                    return

                params.append(goal_id)
                conn.execute(
                    f"UPDATE goals SET {', '.join(updates)} WHERE id = ?", params
                )

                # If status changed to achieved, set achieved_at
                if body.get("status") == "achieved":
                    conn.execute(
                        "UPDATE goals SET achieved_at = datetime('now') WHERE id = ?",
                        (goal_id,),
                    )

                # Log check-in
                note = body.get("note", "")
                if not note and "status" in body:
                    note = f"Status changed to {body['status']}"
                conn.execute(
                    """INSERT INTO goal_checkins (id, goal_id, date, progress, note, source)
                       VALUES (?, ?, date('now'), ?, ?, ?)""",
                    (
                        uuid.uuid4().hex[:16],
                        goal_id,
                        body.get("progress"),
                        note,
                        body.get("source", "dashboard"),
                    ),
                )

                conn.commit()
                conn.close()
                self._json_response({"status": "updated"})
            except Exception as e:
                self._json_response({"error": str(e)}, 400)
            return

        self._json_response({"error": "not found"}, 404)

    def do_OPTIONS(self):
        """Handle CORS preflight."""
        self.send_response(200)
        self._cors_headers()
        self.end_headers()

    def _read_body(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        return json.loads(raw)

    def _json_response(self, data, status=200):
        self.send_response(status)
        self._cors_headers()
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def _cors_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, PUT, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def log_message(self, format, *args):
        """Suppress default access logs unless errors."""
        if args and str(args[0]).startswith(("4", "5")):
            super().log_message(format, *args)


def main():
    os.chdir(DASHBOARD_DIR)

    if "--daemon" in sys.argv:
        # Detach for launchd
        if os.fork():
            sys.exit(0)

    import socket
    HTTPServer.allow_reuse_address = True
    server = HTTPServer(("127.0.0.1", PORT), DashboardHandler)
    server.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    print(f"HYDRA Dashboard: http://localhost:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.shutdown()


if __name__ == "__main__":
    main()
