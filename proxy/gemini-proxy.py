#!/usr/bin/env python3
"""
gemini-proxy.py – Apple II ↔ Gemini TCP Proxy
=========================================================
A lightweight, asynchronous TCP proxy that connects a vintage
Apple II to the Gemini API. Wraps text for an 80-column Videx
Ultraterm, uses Gemini's native Google Search for live data.
Includes aggressive keepalives, ghost-session termination,
and exponential backoff on API rate limits.
"""

import asyncio
import os
import re
import signal
import sys
import textwrap
import argparse
import socket
import unicodedata
from datetime import datetime
from google import genai
from google.genai import types

DEFAULT_PORT = 5000
DEFAULT_MODEL = "gemini-2.5-flash"
DEFAULT_LOCATION = "Cupertino, CA"
DEFAULT_WIDTH = 80
MAX_RETRIES = 3
BASE_BACKOFF = 2.0  # seconds

def get_system_prompt(location: str) -> str:
    current_time = datetime.now().strftime("%A, %B %d, %Y at %I:%M %p")
    return (
        f"You are an intelligent, concise, honest AI assistant with undertones of wit and humor.\n"
        f"Current system time: {current_time}\n"
        f"User's default location: {location}\n"
        "Github repo: https://github.com/junkwax/apple2-ai\n"
        "Version: 1.0\n"
        "Contact: timappl@junkwax.nl\n\n"
        "FORMATTING & STYLE RULES:\n"
        "- Output plain ASCII only. NO markdown, asterisks, backticks, underscores, or #.\n"
        "- Do not use CITE: number or numbers at the end of a sentence. It is not needed\n"
        "- RESPOND IN ALL CAPS.\n"
        "- Use Google Search to fetch live news, weather, or market data when asked.\n"
        "- Be helpful, and natural. Do NOT act like a robotic machine.\n"
        "- Keep responses concise. Aim for 3-8 lines when possible.\n"
        "- For longer topics, use short paragraphs separated by blank lines. Maximum 2 to 3 paragraphs.\n"
        "- GAME MODE: When playing games like Tic-Tac-Toe, ONLY print your move, draw the board using ASCII characters, letters and numbers.\n"
        "- GAME MODE: The game board should only be drawn once per reply\n"
        "- If asked for weather without a city, ask the user.\n"
        "- Most of all have fun with it!"
    )

# Server-side console colours
G = "\033[32m"; C = "\033[36m"; R = "\033[31m"; W = "\033[0m"; Y = "\033[33m"

# Global dictionary to track active connections by IP address
active_sessions = {}

# Unicode → ASCII substitution map
UNICODE_MAP = str.maketrans({
    '\u2018': "'",   # '
    '\u2019': "'",   # '
    '\u201C': '"',   # "
    '\u201D': '"',   # "
    '\u2013': '-',   # –
    '\u2014': '--',  # —
    '\u2026': '...', # …
    '\u2022': '*',   # •
    '\u00B0': ' deg',# °
    '\u00A9': '(c)', # ©
    '\u00AE': '(R)', # ®
    '\u00BD': '1/2', # ½
    '\u00BC': '1/4', # ¼
    '\u00BE': '3/4', # ¾
    '\u00D7': 'x',   # ×
    '\u2212': '-',   # −
    '\u00B7': '*',   # ·
    '\u2192': '->',  # →
    '\u2190': '<-',  # ←
    '\u2713': '[OK]', # ✓
    '\u2714': '[OK]', # ✔
    '\u2717': '[X]',  # ✗
    '\u2718': '[X]',  # ✘
    '\u00A0': ' ',   # non-breaking space
})

def sanitise_and_wrap(text: str, width: int = DEFAULT_WIDTH) -> str:
    # 0a. Strip Gemini tags (case insensitive!)
    text = re.sub(r"<[^>]*>", "", text, flags=re.IGNORECASE)
    # 0b. Strip standard numeric citations like [1] or [1, 2]
    text = re.sub(r"\[\d+(?:,\s*\d+)*\]", "", text)
    # 0c. Catch leftover literal "CITE: 1" just in case the AI prints it directly
    text = re.sub(r"CITE:\s*\d+(?:,\s*\d+)*", "", text, flags=re.IGNORECASE)
    
    # 1. Strip markdown formatting
    text = re.sub(r"[*`#~_\[\]]", "", text)

    # 2. Unicode → ASCII substitution
    text = text.translate(UNICODE_MAP)

    # 3. Normalize remaining Unicode
    text = unicodedata.normalize('NFKD', text)

    # 4. Force pure printable ASCII
    text = "".join(c if (32 <= ord(c) <= 126 or c == '\n') else " " for c in text)

    # 5. Collapse multiple spaces
    text = re.sub(r"[ \t]+", " ", text)

    # 6. Collapse 3+ consecutive blank lines into 2
    text = re.sub(r"\n{3,}", "\n\n", text)
    
    # 7. Strip out any "Assistant:" prefix the AI might sneak in
    text = re.sub(r"^Assistant:?\s*", "", text, flags=re.IGNORECASE)

    # 8. Word wrap each paragraph
    wrapped_lines = []
    for paragraph in text.split('\n'):
        stripped = paragraph.strip()
        if stripped == '':
            wrapped_lines.append('')
        else:
            wrapped_lines.extend(textwrap.wrap(stripped, width=width))

    return "\r\n".join(wrapped_lines).strip()

class ChatSession:
    def __init__(self, reader, writer, client, model, location, width):
        self.reader = reader
        self.writer = writer
        self.client = client
        self.model = model
        self.width = width
        peer = writer.get_extra_info("peername")
        self.ip = peer[0] if peer else "unknown"
        self.addr = f"{peer[0]}:{peer[1]}" if peer else "?"

        self.chat = self.client.chats.create(
            model=self.model,
            config=types.GenerateContentConfig(
                system_instruction=get_system_prompt(location),
                tools=[{"google_search": {}}],
                temperature=0.3
            )
        )

    async def send_text(self, text: str):
        """Stream text to the Apple II character by character."""
        for char in text:
            self.writer.write(char.encode("ascii", errors="replace"))
            await self.writer.drain()
            
            # Micro-pause on punctuation to simulate organic typing
            if char in ['.', ',', '!', '?', ':']:
                await asyncio.sleep(0.08)
            else:
                await asyncio.sleep(0.003)

        # Null terminator signals end-of-response to the Apple II
        self.writer.write(b"\x00")
        await self.writer.drain()

    async def query_gemini(self, message: str) -> str:
        """Send message to Gemini with exponential backoff on failures."""
        last_error = None
        for attempt in range(MAX_RETRIES):
            try:
                response = await asyncio.to_thread(
                    self.chat.send_message, message
                )
                return response.text
            except Exception as e:
                last_error = e
                err_str = str(e)
                # Rate limit or server error — back off and retry
                if '503' in err_str or '429' in err_str or 'RESOURCE_EXHAUSTED' in err_str:
                    wait = BASE_BACKOFF * (2 ** attempt)
                    print(f"{Y}[!] API rate limit (attempt {attempt+1}/{MAX_RETRIES}), "
                          f"retrying in {wait:.0f}s...{W}")
                    await asyncio.sleep(wait)
                else:
                    # Non-retryable error
                    raise
        raise last_error

    async def run(self):
        # --- 1. Ghost session cleanup ---
        if self.ip in active_sessions:
            print(f"{Y}[!] Ghost session from {self.ip}. Killing old connection.{W}")
            old_writer = active_sessions[self.ip]
            try:
                old_writer.close()
            except Exception:
                pass

        active_sessions[self.ip] = self.writer

        # --- 2. Aggressive keepalives ---
        sock = self.writer.get_extra_info('socket')
        if sock:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
            if hasattr(socket, 'TCP_KEEPIDLE'):
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, 10)
            if hasattr(socket, 'TCP_KEEPINTVL'):
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, 3)
            if hasattr(socket, 'TCP_KEEPCNT'):
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, 3)

        print(f"{G}[+] {self.addr} connected{W}")
        try:
            while True:
                try:
                    # Removed the 1-hour timeout. Wait indefinitely!
                    raw = await self.reader.readline()
                except Exception:
                    break

                if not raw:
                    break
                message = raw.decode("ascii", errors="replace").strip()
                if not message:
                    continue

                print(f"{C}[>] {self.addr}: {message}{W}")

                try:
                    response_text = await self.query_gemini(message)
                    clean_text = sanitise_and_wrap(response_text, self.width)

                    # Print the exact wrapped text with no extra double-line gaps
                    print(f"{G}[<] {self.addr}:\n{clean_text}{W}")
                    await self.send_text(clean_text)

                except Exception as e:
                    error_msg = str(e)[:60]
                    print(f"{R}[!] {self.addr} error: {e}{W}")
                    await self.send_text(f"[ERROR: {error_msg}]\r\n")

        except (ConnectionResetError, BrokenPipeError, OSError):
            pass
        finally:
            if active_sessions.get(self.ip) == self.writer:
                del active_sessions[self.ip]
            try:
                self.writer.close()
                await self.writer.wait_closed()
            except Exception:
                pass
            print(f"[-] {self.addr} disconnected")


async def amain(host: str, port: int, model: str, location: str, width: int):
    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key:
        print(f"{R}ERROR: Set GEMINI_API_KEY environment variable.{W}")
        sys.exit(1)

    client = genai.Client(api_key=api_key)

    async def handle(r, w):
        await ChatSession(r, w, client, model, location, width).run()

    server = await asyncio.start_server(handle, host, port)

    print(f"\n")
    print(f" ██████╗ ███████╗███╗   ███╗██╗███╗   ██╗██╗")
    print(f"██╔════╝ ██╔════╝████╗ ████║██║████╗  ██║██║")
    print(f"██║  ███╗█████╗  ██╔████╔██║██║██╔██╗ ██║██║")
    print(f"██║   ██║██╔══╝  ██║╚██╔╝██║██║██║╚██╗██║██║")
    print(f"╚██████╔╝███████╗██║ ╚═╝ ██║██║██║ ╚████║██║")
    print(f" ╚═════╝ ╚══════╝╚═╝     ╚═╝╚═╝╚═╝  ╚═══╝╚═╝")
    print(f"")
    print(f"  APPLE ][ AI PROXY")
    print(f"  Port: {port} | Model: {model}")
    print(f"  Wrap: {width} cols | Location: {location}")
    print(f"  Keepalives: ON | Ghost cleanup: ON")
    print(f"  Retries: {MAX_RETRIES} with exponential backoff")
    print(f"")
    print(f"  Waiting for Apple II connection...\n")

    # --- Signal handling (cross-platform) ---
    loop = asyncio.get_running_loop()
    stop = loop.create_future()

    if sys.platform != 'win32':
        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(sig, lambda: stop.set_result(None))

    async with server:
        try:
            if sys.platform != 'win32':
                await stop
            else:
                await asyncio.Event().wait()  # Run forever, Ctrl-C raises KeyboardInterrupt
        except (KeyboardInterrupt, asyncio.CancelledError):
            pass

    print(f"\n[*] Proxy shut down.")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(
        description="Apple II ↔ Gemini API TCP proxy",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=textwrap.dedent("""\
            examples:
              %(prog)s --port 5000 --model gemini-2.5-flash
              %(prog)s --location "Cupertino, CA" --width 78
        """)
    )
    ap.add_argument("--host", default="0.0.0.0",
                    help="Bind address (default: 0.0.0.0)")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT,
                    help=f"TCP port (default: {DEFAULT_PORT})")
    ap.add_argument("--model", default=DEFAULT_MODEL,
                    help=f"Gemini model (default: {DEFAULT_MODEL})")
    ap.add_argument("--location", default=DEFAULT_LOCATION,
                    help=f"Default location for queries (default: {DEFAULT_LOCATION})")
    ap.add_argument("--width", type=int, default=DEFAULT_WIDTH,
                    help=f"Line wrap width in columns (default: {DEFAULT_WIDTH})")
    args = ap.parse_args()

    try:
        asyncio.run(amain(args.host, args.port, args.model, args.location, args.width))
    except KeyboardInterrupt:
        print(f"\n[*] Proxy shut down.")