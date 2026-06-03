from flask import Flask

app = Flask(__name__)


@app.get("/")
def root():
    return {"ok": "from pip+flask"}
