"""Send a recording from a problem report to the speech Worker again.

    SPEECH_WORKER_TOKEN=... python scripts/retranscribe.py recording.wav [--url https://...]

Uses Yating quota and sends the audio out: run it only with the user's OK.
The token is read from the environment so it never lands in a file or log.
Needs Python 3.12+ (its `wave` reads the WAVE_FORMAT_EXTENSIBLE files iPadOS writes).
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request
import wave

DEFAULT_URL = "https://reminicare-speech-api.hding49.workers.dev"


def pcm(path: str) -> bytes:
    with wave.open(path, "rb") as audio:
        shape = (audio.getframerate(), audio.getnchannels(), audio.getsampwidth())
        if shape != (16000, 1, 2):
            sys.exit(f"需要 16 kHz 單聲道 16-bit，這個檔案是 {shape[0]} Hz、{shape[1]} 聲道、{shape[2] * 8}-bit")
        return audio.readframes(audio.getnframes())


def main() -> None:
    parser = argparse.ArgumentParser(description="用 speech Worker 重新辨識一段 WAV 錄音")
    parser.add_argument("file")
    parser.add_argument("--url", default=DEFAULT_URL, help="speech Worker 網址")
    args = parser.parse_args()
    token = os.environ.get("SPEECH_WORKER_TOKEN", "").strip()
    if not token:
        sys.exit("請先設定環境變數 SPEECH_WORKER_TOKEN（Worker 的 APP_TOKEN）")
    body = pcm(args.file)
    print(f"錄音 {len(body) / 32000:.1f} 秒，送出辨識…", file=sys.stderr)
    request = urllib.request.Request(
        args.url.rstrip("/") + "/v1/transcribe", data=body, method="POST",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/octet-stream"},
    )
    try:
        with urllib.request.urlopen(request, timeout=len(body) / 32000 + 60) as response:
            result = json.load(response)
    except urllib.error.HTTPError as error:
        sys.exit(f"HTTP {error.code}：{error.read().decode(errors='replace')}")
    print(f"句數：{result.get('sentences')}")
    print(f"文字：{result.get('text') or '（空字串）'}")


if __name__ == "__main__":
    main()
