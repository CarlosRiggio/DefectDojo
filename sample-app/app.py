"""Minimal Flask app used as a scan target for the local SAST/DAST -> DefectDojo pipeline.

Deliberately small: a handful of routes are enough to give Semgrep and OWASP ZAP
something real to analyze without the app itself being the point of the demo.
"""

from flask import Flask, request

app = Flask(__name__)


@app.route("/")
def index():
    return "Sample app for the DefectDojo SAST/DAST POC pipeline.\n"


@app.route("/health")
def health():
    return {"status": "ok"}


@app.route("/greet")
def greet():
    # Reflects the "name" query param straight into the HTML response without
    # escaping. Left in on purpose as a realistic, easy-to-explain target for
    # both Semgrep (reflected-input rules) and ZAP's active scan rules -
    # the whole point of this app is to give the scanners something to find.
    name = request.args.get("name", "world")
    return f"<p>Hello, {name}!</p>"


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
