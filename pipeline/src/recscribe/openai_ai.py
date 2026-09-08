"""Explicit text-only OpenAI adapter. Fixed TLS origin, no redirects or retries.

Keys arrive over stdin, never arguments, environment, artifacts or diagnostics.
https://developers.openai.com/api/docs/guides/structured-outputs
"""
import http.client
import json
import socket
import sys
import threading

HOST = "api.openai.com"
MAX_RESPONSE_BYTES = 4 * 1024 * 1024
MAX_KEY_BYTES = 2048
REQUEST_TIMEOUT = 180
MAX_OUTPUT_TOKENS = 8192


def read_key(stream):
    key = stream.read(MAX_KEY_BYTES + 1).strip()
    if not key or len(key) > MAX_KEY_BYTES or any(c.isspace() or not c.isascii() for c in key):
        raise ValueError("Missing or invalid OpenAI key; save it in RecScribe Settings")
    return key


def request(route, key, payload=None, cancel=None):
    if route not in ("models", "responses"):
        raise ValueError("Unsupported OpenAI route")
    connection = http.client.HTTPSConnection(HOST, timeout=REQUEST_TIMEOUT)
    stopped = threading.Event()
    def watch():
        while not stopped.wait(0.1):
            try:
                cancel.check()
            except Exception:
                if connection.sock:
                    try: connection.sock.shutdown(socket.SHUT_RDWR)
                    except OSError: pass
                connection.close()
                return
    watcher = threading.Thread(target=watch, daemon=True) if cancel else None
    try:
        if cancel:
            cancel.check()
            watcher.start()
        connection.request("GET" if payload is None else "POST", "/v1/" + route,
                           None if payload is None else json.dumps(payload).encode(),
                           {"Content-Type": "application/json", "Authorization": "Bearer " + key})
        response = connection.getresponse()
        data = response.read(MAX_RESPONSE_BYTES + 1)
        if response.status != 200:
            # Never echo response bodies: they may reflect transcript data.
            raise ValueError(f"OpenAI request failed: HTTP {response.status}. Check the key, model access and billing; no fallback or retry was used.")
        if len(data) > MAX_RESPONSE_BYTES:
            raise ValueError("OpenAI response exceeds the safe size limit")
        result = json.loads(data)
        if not isinstance(result, dict):
            raise ValueError("Invalid OpenAI response")
        return result
    finally:
        stopped.set()
        connection.close()
        if watcher and watcher.ident:
            watcher.join(timeout=1)
        if cancel:
            cancel.check()


def object_schema(properties):
    return {"type": "object", "properties": properties,
            "required": list(properties), "additionalProperties": False}


RESULT_SCHEMA = object_schema({
    "segments": {"type": "array", "items": object_schema({"id": {"type": "string"}, "text": {"type": "string"}})},
    "notes": {"type": "array", "items": object_schema({"text": {"type": "string"},
        "segment_ids": {"type": "array", "items": {"type": "string"}}})},
})


def generate(payload, key, cancel):
    raw = request("responses", key, {
        "model": payload["model"], "store": False, "max_output_tokens": MAX_OUTPUT_TOKENS,
        "input": [{"role": "system", "content": payload["system"]},
                  {"role": "user", "content": payload["prompt"]}],
        "text": {"format": {"type": "json_schema", "name": "transcript_derivation",
                            "strict": True, "schema": RESULT_SCHEMA}},
    }, cancel)
    if raw.get("status") != "completed":
        raise ValueError("OpenAI response incomplete; original transcript retained")
    content = [c for item in raw.get("output", []) if item.get("type") == "message"
               for c in item.get("content", [])]
    if any(c.get("type") == "refusal" for c in content):
        raise ValueError("OpenAI declined this request; original transcript retained")
    text = "".join(c["text"] for c in content if c.get("type") == "output_text")
    if not text:
        raise ValueError("OpenAI returned no text")
    usage = raw.get("usage") or {}
    return {"done": True, "response": text, "provider_response": raw,
            "prompt_eval_count": usage.get("input_tokens"), "eval_count": usage.get("output_tokens")}


if __name__ == "__main__":
    try:
        result = request("models", read_key(sys.stdin))
        print(json.dumps(sorted({m["id"] for m in result.get("data", []) if isinstance(m.get("id"), str)})))
    except (OSError, ValueError, http.client.HTTPException):
        print("OpenAI connection test failed. Check the saved key, network and API access. No transcript was sent.", file=sys.stderr)
        raise SystemExit(1)
