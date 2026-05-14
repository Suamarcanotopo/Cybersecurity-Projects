"""
©AngelaMos | 2026
app.py
"""

from flask import Flask, jsonify, request

app = Flask(__name__)
TOKENS: dict[int, dict] = {}
NEXT_ID = 100000


@app.route("/user", methods=["GET"])
def user():
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        return jsonify({"message": "Bad credentials"}), 401
    return jsonify({"login": "fake-bot", "id": 1})


@app.route("/user/personal-access-tokens", methods=["POST"])
def create_pat():
    global NEXT_ID
    body = request.get_json() or {}
    pat_id = NEXT_ID
    NEXT_ID += 1
    TOKENS[pat_id] = body
    return jsonify({
        "id": pat_id,
        "token": f"ghp_fake_{pat_id}",
        "expires_at": "2026-12-31T00:00:00Z",
    })


@app.route("/user/personal-access-tokens/<int:pat_id>", methods=["DELETE"])
def delete_pat(pat_id):
    TOKENS.pop(pat_id, None)
    return "", 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=7000)
