import os
import socket
import time

from flask import Flask, abort, jsonify

app = Flask(__name__)

VERSION = os.environ.get("APP_VERSION", "v1")
BROKEN = os.environ.get("BROKEN", "false") == "true"

# Made-up demo data. Play counts are not real.
ARTISTS = {
    1: {"id": 1, "name": "The Weeknd", "monthly_listeners": 110_000_000},
    2: {"id": 2, "name": "Taylor Swift", "monthly_listeners": 95_000_000},
    3: {"id": 3, "name": "Ed Sheeran", "monthly_listeners": 85_000_000},
    4: {"id": 4, "name": "Coldplay", "monthly_listeners": 80_000_000},
    5: {"id": 5, "name": "Queen", "monthly_listeners": 50_000_000},
    6: {"id": 6, "name": "Kishore Kumar", "monthly_listeners": 12_000_000},
}

SONGS = [
    {"id": 101, "title": "Blinding Lights", "artist_id": 1, "plays": 4_900_000_000},
    {"id": 102, "title": "Starboy", "artist_id": 1, "plays": 2_900_000_000},
    {"id": 103, "title": "Save Your Tears", "artist_id": 1, "plays": 2_100_000_000},
    {"id": 201, "title": "Anti-Hero", "artist_id": 2, "plays": 1_800_000_000},
    {"id": 202, "title": "Cruel Summer", "artist_id": 2, "plays": 2_400_000_000},
    {"id": 301, "title": "Shape of You", "artist_id": 3, "plays": 4_100_000_000},
    {"id": 302, "title": "Perfect", "artist_id": 3, "plays": 3_000_000_000},
    {"id": 303, "title": "Photograph", "artist_id": 3, "plays": 1_700_000_000},
    {"id": 401, "title": "Yellow", "artist_id": 4, "plays": 2_000_000_000},
    {"id": 402, "title": "Viva La Vida", "artist_id": 4, "plays": 2_200_000_000},
    {"id": 501, "title": "Bohemian Rhapsody", "artist_id": 5, "plays": 2_600_000_000},
    {"id": 502, "title": "Don't Stop Me Now", "artist_id": 5, "plays": 1_900_000_000},
    {"id": 601, "title": "Pal Pal Dil Ke Paas", "artist_id": 6, "plays": 3_300_000_000},
]


def respond(**data):
    # served_by is the pod name inside Kubernetes, so students can see which copy answered.
    return jsonify({"version": VERSION, "served_by": socket.gethostname(), **data})


def with_artist(song):
    return {**song, "artist": ARTISTS[song["artist_id"]]["name"]}


@app.get("/")
def index():
    return respond(
        service="spotify-api",
        endpoints=[
            "/artists/top",
            "/artists/<id>/songs",
            "/songs/most-listened",
            "/config",
            "/healthz",
            "/readyz",
        ],
    )


@app.get("/artists/top")
def top_artists():
    english = [a for a in ARTISTS.values() if a["id"] != 6]
    ranked = sorted(english, key=lambda a: a["monthly_listeners"], reverse=True)
    return respond(artists=ranked[:5])


@app.get("/artists/<int:artist_id>/songs")
def artist_songs(artist_id):
    if artist_id not in ARTISTS:
        abort(404, description=f"artist {artist_id} not found")
    songs = [with_artist(s) for s in SONGS if s["artist_id"] == artist_id]
    return respond(artist=ARTISTS[artist_id], songs=songs)


@app.get("/songs/most-listened")
def most_listened():
    ranked = sorted(SONGS, key=lambda s: s["plays"], reverse=True)
    return respond(songs=[with_artist(s) for s in ranked[:5]])


@app.get("/config")
def config():
    api_key = os.environ.get("API_KEY", "")
    files = {}
    if os.path.isdir("/config"):
        for name in sorted(os.listdir("/config")):
            path = os.path.join("/config", name)
            if os.path.isfile(path):
                with open(path) as f:
                    files[name] = f.read().strip()
    return respond(
        env={
            "GREETING": os.environ.get("GREETING", "(not set)"),
            "REGION": os.environ.get("REGION", "(not set)"),
            "API_KEY": ("****" + api_key[-4:]) if api_key else "(not set)",
        },
        files_in_config_folder=files,
    )


@app.get("/healthz")
def healthz():
    if os.path.exists("/tmp/not-alive"):
        return respond(status="dead"), 500
    return respond(status="alive")


@app.get("/readyz")
def readyz():
    if BROKEN:
        return respond(status="broken build, never ready"), 503
    if os.path.exists("/tmp/not-ready"):
        return respond(status="not ready"), 503
    return respond(status="ready")


@app.get("/burn")
def burn():
    # Keeps one CPU busy for a short time, used for the autoscaling demo.
    end = time.time() + 0.2
    count = 0
    while time.time() < end:
        count += 1
    return respond(loops=count)
