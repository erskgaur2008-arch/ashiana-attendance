from html.parser import HTMLParser
from pathlib import Path
import subprocess
import tempfile


class ScriptParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.current = None
        self.code = []
        self.scripts = []

    def handle_starttag(self, tag, attrs):
        if tag == "script":
            self.current = dict(attrs)
            self.code = []

    def handle_data(self, data):
        if self.current is not None:
            self.code.append(data)

    def handle_endtag(self, tag):
        if tag == "script" and self.current is not None:
            if not self.current.get("src"):
                self.scripts.append((self.current.get("type", "").lower(), "".join(self.code)))
            self.current = None


def check(code, suffix, label):
    with tempfile.NamedTemporaryFile("w", suffix=suffix, encoding="utf-8", delete=False) as file:
        file.write(code)
        path = Path(file.name)
    try:
        result = subprocess.run(["node", "--check", str(path)], capture_output=True, text=True)
        if result.returncode:
            raise SystemExit(f"{label} failed JavaScript syntax check:\n{result.stderr}")
    finally:
        path.unlink(missing_ok=True)


check(Path("portal-passkey-lock.js").read_text(encoding="utf-8"), ".js", "portal-passkey-lock.js")
check(Path("mobile/native-bridge.js").read_text(encoding="utf-8"), ".mjs", "mobile/native-bridge.js")

parser = ScriptParser()
parser.feed(Path("index.html").read_text(encoding="utf-8"))
checked = 0
for script_type, code in parser.scripts:
    if script_type in {"application/json", "application/ld+json", "importmap"} or not code.strip():
        continue
    check(code, ".mjs" if script_type == "module" else ".js", f"index.html inline script {checked + 1}")
    checked += 1

print(f"Checked portal JavaScript and {checked} inline script blocks in index.html")
