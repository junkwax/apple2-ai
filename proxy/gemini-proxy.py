#!/usr/bin/env python3
"""
gemini-proxy.py – Apple II ↔ Gemini TCP Proxy
=========================================================
A lightweight, asynchronous TCP proxy that connects a vintage
Apple II to the Gemini API. Automatically wraps text to 80
columns and uses Gemini's native Google Search for live data.
Includes aggressive keepalives and ghost-session termination.
"""

import asyncio
import os
import re
import signal
import sys
import textwrap
import argparse
import socket
from datetime import datetime
from google import genai
from google.genai import types

DEFAULT_PORT = 5000
DEFAULT_MODEL = "gemini-3-flash-preview"
DEFAULT_LOCATION = "Cupertino, CA"

def get_system_prompt(location: str) -> str:
    current_time = datetime.now().strftime("%A, %B %d, %Y at %I:%M %p")
    return f"""You are a intelligent, concise AI assistant
    Current system time: {current_time}
    User's default location: {location}

    FORMATTING & STYLE RULES:

    - Output plain ASCII only. NO markdown, asterisks, backticks, underscores, or #.
    - RESPOND IN ALL CAPS.
    - Be helpful, and natural. Do NOT act like a robotic machine.
    - Think of text based games you can play with the user if they ask. Use simple ASCII art if needed, but keep it minimal.
    - GAME MODE: When playing games like Tic-Tac-Toe, ONLY print your move, and prompt the user. Omit ALL chatty filler.
    - Use Google Search to fetch live news, weather, or market data when asked.
    - If asked for weather without a city, ask the user.
    - Most of all have fun with it! Be creative and engaging, but keep it concise and Apple II friendly."""

# Server-side console colours
G = "\033[32m"; C = "\033[36m"; R = "\033[31m"; W = "\033[0m"; Y = "\033[33m"

# Global dictionary to track active connections by IP address
active_sessions = {}

def sanitise_and_wrap(text: str) -> str:
    """Strip markdown, force ASCII, and hard-wrap to 79 columns for the Apple II."""
    text = re.sub(r'[*`#~_\[\]]', '', text)
    text = ''.join(c if (32 <= ord(c) <= 126 or c == '\n') else ' ' for c in text)

    wrapped_lines = []
    for paragraph in text.split('\n'):
        if paragraph.strip() == '':
            wrapped_lines.append('')
        else:
            wrapped_lines.extend(textwrap.wrap(paragraph, width=79))

    # Join with standard carriage return + line feed
    return '\r\n'.join(wrapped_lines).strip()

class ChatSession:
    def __init__(self, reader, writer, client, model, location):
        self.reader = reader
        self.writer = writer
        self.client = client
        self.model = model
        peer = writer.get_extra_info("peername")
        self.ip = peer[0] if peer else "unknown"
        self.addr = f"{peer[0]}:{peer[1]}" if peer else "?"

        # Initialize Gemini chat session with native Google Search enabled
        self.chat = self.client.chats.create(
            model=self.model,
            config=types.GenerateContentConfig(
                system_instruction=get_system_prompt(location),
                tools=[{"google_search": {}}],  # Enables live web grounding
                temperature=0.3
            )
        )

    async def run(self):
        # --- 1. THE HIGHLANDER CONNECTION MANAGER ---
        # If this IP already has an active connection (ghost session), kill it.
        if self.ip in active_sessions:
            print(f"{Y}[!] Ghost connection detected from {self.ip}. Terminating old session.{W}")
            old_writer = active_sessions[self.ip]
            try:
                old_writer.close()
            except Exception:
                pass

        # Register this new connection
        active_sessions[self.ip] = self.writer

        # --- 2. AGGRESSIVE KEEPALIVE LOGIC ---
        sock = self.writer.get_extra_info('socket')
        if sock:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
            # After 10 seconds of silence, OS starts probing the Apple II
            if hasattr(socket, 'TCP_KEEPIDLE'):
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, 10)
            # Send a probe every 3 seconds
            if hasattr(socket, 'TCP_KEEPINTVL'):
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, 3)
            # Drop connection completely after 3 failed probes (Total time: ~19s)
            if hasattr(socket, 'TCP_KEEPCNT'):
                sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, 3)

        print(f"{G}[+] {self.addr} connected{W}")
        try:
            while True:
                try:
                    raw = await asyncio.wait_for(self.reader.readline(), timeout=600.0)
                except asyncio.TimeoutError:
                    break

                if not raw: break
                message = raw.decode("ascii", errors="replace").strip()
                if not message: continue

                print(f"{C}[>] {self.addr}: {message}{W}")

                try:
                    # Run the blocking Gemini call in a thread
                    response = await asyncio.to_thread(self.chat.send_message, message)

                    clean_text = sanitise_and_wrap(response.text)
                    print(f"{G}[<] {self.addr}:\n{clean_text}{W}")

                    # Stream character by character at ~1200 baud
                    for char in clean_text:
                        self.writer.write(char.encode("ascii", errors="replace"))
                        await self.writer.drain()
                        await asyncio.sleep(0.005)

                    self.writer.write(b"\x00")
                    await self.writer.drain()

                except Exception as e:
                    print(f"{R}[!] Error: {e}{W}")
                    self.writer.write(b"\xffERROR PROCESSING REQUEST\x00")
                    await self.writer.drain()

        except (ConnectionResetError, BrokenPipeError):
            pass
        finally:
            # Clean up the session registry when disconnecting
            if active_sessions.get(self.ip) == self.writer:
                del active_sessions[self.ip]
            self.writer.close()
            print(f"[-] {self.addr} disconnected")

async def amain(host: str, port: int, model: str, location: str):
    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key:
        print(f"{R}ERROR: Set GEMINI_API_KEY environment variable.{W}")
        sys.exit(1)

    client = genai.Client(api_key=api_key)

    async def handle(r, w):
        await ChatSession(r, w, client, model, location).run()

    server = await asyncio.start_server(handle, host, port)
    print(f"\n\n                                             ")
    print(f" ██████╗ ███████╗███╗   ███╗██╗███╗   ██╗██╗")
    print(f"██╔════╝ ██╔════╝████╗ ████║██║████╗  ██║██║")
    print(f"██║  ███╗█████╗  ██╔████╔██║██║██╔██╗ ██║██║")
    print(f"██║   ██║██╔══╝  ██║╚██╔╝██║██║██║╚██╗██║██║")
    print(f"╚██████╔╝███████╗██║ ╚═╝ ██║██║██║ ╚████║██║")
    print(f" ╚═════╝ ╚══════╝╚═╝     ╚═╝╚═╝╚═╝  ╚═══╝╚═╝")
    print(f"\n[*] GEMINI PROXY RUNNING on Port {port}")
    print(f"[*] Model: {model} | Grounding: Google Search Enabled")
    print(f"[*] Default Location: {location}")
    print(f"[*] Aggressive Keepalives & Session Manager: ACTIVE\n")

    loop = asyncio.get_running_loop()
    stop = loop.create_future()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, lambda: stop.set_result(None))

    async with server:
        await stop

if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Apple II ↔ Gemini API TCP proxy")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--location", default=DEFAULT_LOCATION, help="Set the default location for queries")
    args = ap.parse_args()

    asyncio.run(amain(args.host, args.port, args.model, args.location))