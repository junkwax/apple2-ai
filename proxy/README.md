# Gemini Proxy

Asynchronous Python TCP relay between the Apple II and the Gemini API.

## Requirements

```bash
pip install google-genai
```

## Setup

1. Get a free API key from [Google AI Studio](https://aistudio.google.com/apikey).

2. Set the environment variable:
   ```bash
   # Linux / macOS
   export GEMINI_API_KEY="your_key_here"

   # Windows (Command Prompt)
   set GEMINI_API_KEY=your_key_here
   ```

3. Run:
   ```bash
   python3 gemini-proxy.py --host 0.0.0.0 --port 5000
   ```

## Options

| Flag | Default | Description |
|------|---------|-------------|
| `--host` | `0.0.0.0` | Bind address (all interfaces) |
| `--port` | `5000` | TCP port the Apple II connects to |
| `--model` | `gemini-2.0-flash` | Gemini model to use |
| `--location` | `Cupertino, CA` | Default location for weather/local queries |

## What It Does

- Listens for raw ASCII lines from the Apple II over a plain TCP socket
- Wraps each message in a Gemini API request with Google Search grounding enabled
- Strips markdown, converts to uppercase ASCII, word-wraps to 79 columns
- Streams the response back character-by-character at ~1200 baud pacing
- **Ghost Session Manager** — If the Apple II is power-cycled without disconnecting, the proxy detects the new connection from the same IP and kills the stale session
- **Aggressive TCP Keepalives** — Probes the Apple II after 10 seconds of silence, drops dead connections after ~19 seconds
