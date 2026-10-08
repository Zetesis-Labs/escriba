#!/usr/bin/env python3
"""PROTOTYPE: npm -> esbuild WASM/JSC -> connector JSC -> Swift -> fake HTTP.

No production data, real credential, external API or app source is used.
Artifacts are disposable and live in .scratch/PROTOTYPE-*.
"""
from __future__ import annotations

import hashlib
import io
import json
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import wave
from email import policy
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parent
TOKEN = "poc-swift-only-credential"


class FakeNotion:
    def __init__(self):
        self.pages = {}
        self.uploads = {}
        self.requests = []
        self.fail_next = None
        self.block_sequence = 0

    def page(self, data):
        page_id = f"page-{len(self.pages) + 1}"
        result = {"object": "page", "id": page_id,
                  "url": f"https://example.invalid/{page_id}",
                  "archived": False, "properties": data.get("properties", {}),
                  "blocks": []}
        self.pages[page_id] = result
        return {key: value for key, value in result.items() if key != "blocks"}


def handler_for(state):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def respond(self, status, value, headers=None):
            body = json.dumps(value, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            for name, value in (headers or {}).items():
                self.send_header(name, value)
            self.end_headers()
            self.wfile.write(body)

        def dispatch(self):
            parsed = urlsplit(self.path)
            path = parsed.path
            raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            authenticated = self.headers.get("Authorization") == f"Bearer {TOKEN}"
            record = {"method": self.command, "path": path,
                      "query": parse_qs(parsed.query), "authenticated": authenticated,
                      "bodyBytes": len(raw)}
            state.requests.append(record)
            if not authenticated:
                return self.respond(401, {"object": "error", "code": "unauthorized", "message": "Missing host credential"})
            if path == "/poc/redirect":
                return self.respond(302, {}, {"Location": "/poc/redirect-target"})
            if path == "/poc/headers":
                return self.respond(200, {"echo": TOKEN},
                                    {"Authorization": f"Bearer {TOKEN}", "Set-Cookie": f"secret={TOKEN}"})
            data = json.loads(raw) if raw and "application/json" in self.headers.get("Content-Type", "") else {}
            if path == "/v1/pages" and self.command == "POST":
                failure, state.fail_next = state.fail_next, None
                if failure == "rate-limit":
                    return self.respond(429, {"object": "error", "status": 429, "code": "rate_limited", "message": "Synthetic rate limit"}, {"Retry-After": "0"})
                page = state.page(data)
                if failure == "uncertain-create":
                    self.connection.shutdown(socket.SHUT_RDWR)
                    self.connection.close()
                    return
                if failure == "append":
                    state.fail_next = failure
                return self.respond(200, page)
            if path.startswith("/v1/pages/") and self.command == "PATCH":
                page = state.pages[path.split("/")[-1]]
                page.update(data)
                return self.respond(200, {k: v for k, v in page.items() if k != "blocks"})
            if path.startswith("/v1/blocks/") and path.endswith("/children"):
                page = state.pages[path.split("/")[3]]
                if self.command == "GET":
                    offset = int(parse_qs(parsed.query).get("start_cursor", ["0"])[0])
                    blocks = page["blocks"]
                    # A deliberately small page forces real SDK pagination.
                    end = min(offset + 1, len(blocks))
                    return self.respond(200, {"object": "list", "results": blocks[offset:end], "has_more": end < len(blocks), "next_cursor": str(end) if end < len(blocks) else None})
                if self.command == "PATCH":
                    if state.fail_next == "append":
                        state.fail_next = None
                        return self.respond(500, {"object": "error", "status": 500, "code": "internal_server_error", "message": "Synthetic append failure"})
                    added = []
                    for child in data["children"]:
                        state.block_sequence += 1
                        added.append({**child, "id": f"block-{state.block_sequence}"})
                    page["blocks"].extend(added)
                    return self.respond(200, {"object": "list", "results": added, "has_more": False, "next_cursor": None})
            if path.startswith("/v1/blocks/") and self.command == "DELETE":
                block_id = path.split("/")[-1]
                for page in state.pages.values():
                    page["blocks"] = [b for b in page["blocks"] if b["id"] != block_id]
                return self.respond(200, {"object": "block", "id": block_id, "archived": True})
            if path == "/v1/file_uploads" and self.command == "POST":
                upload_id = f"upload-{len(state.uploads) + 1}"
                state.uploads[upload_id] = {"id": upload_id, "status": "pending"}
                return self.respond(200, state.uploads[upload_id])
            if path.startswith("/v1/file_uploads/") and path.endswith("/send"):
                upload = state.uploads[path.split("/")[3]]
                message = BytesParser(policy=policy.default).parsebytes(
                    f"Content-Type: {self.headers['Content-Type']}\r\nMIME-Version: 1.0\r\n\r\n".encode() + raw)
                files = [part for part in message.iter_parts() if part.get_param("name", header="content-disposition") == "file"]
                if len(files) != 1:
                    return self.respond(400, {"object": "error", "code": "validation_error", "message": "Missing multipart file"})
                part = files[0]
                upload.update(status="uploaded", filename=part.get_filename(),
                              contentType=part.get_content_type(), bytes=list(part.get_payload(decode=True)))
                return self.respond(200, {"id": upload["id"], "status": "uploaded"})
            return self.respond(404, {"object": "error", "code": "object_not_found", "message": f"Unimplemented fake endpoint {path}"})

        do_GET = do_POST = do_PATCH = do_DELETE = dispatch
    return Handler


def main():
    if sys.platform != "darwin":
        raise SystemExit("Esta prueba requiere macOS y JavaScriptCore del sistema.")
    if not (ROOT / "node_modules/esbuild-wasm/esbuild.wasm").exists():
        raise SystemExit("Primero ejecuta npm ci --ignore-scripts --no-audit --no-fund en este directorio.")
    scratch = ROOT / ".scratch"
    scratch.mkdir(exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="PROTOTYPE-", dir=scratch))
    cache = scratch / "swift-module-cache"
    checks = []
    metrics = {}
    completed = False

    def check(name, condition, detail=None):
        checks.append({"name": name, "passed": bool(condition), "detail": detail})
        print(f"{'PASS' if condition else 'FAIL'} {name}", flush=True)
        if not condition:
            raise AssertionError(f"{name}: {detail}")

    state = FakeNotion()
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler_for(state))
    server.daemon_threads = True
    origin = f"http://127.0.0.1:{server.server_port}"
    threading.Thread(target=server.serve_forever, daemon=True).start()
    started = time.monotonic()
    try:
        # Native probe executables, built once; neither is part of the app.
        executables = work / "bin"
        executables.mkdir()
        compiler, runtime = executables / "compile", executables / "run"
        for source, executable in ((ROOT / "compiler/compile.swift", compiler), (ROOT / "runtime/run.swift", runtime)):
            result = subprocess.run(["swiftc", "-module-cache-path", str(cache), str(source), "-o", str(executable)], capture_output=True, text=True, timeout=90)
            check(f"Host nativo de prueba compilado: {executable.name}", result.returncode == 0, result.stderr[-2000:])
        shutil.copyfile(ROOT / "runtime/prelude.js", executables / "prelude.js")
        # The compiler sees a real conventional npm tree within a disposable root.
        project = work / "workspace"
        project.mkdir()
        shutil.copytree(ROOT / "project", project / "project")
        shutil.copytree(ROOT / "node_modules", project / "node_modules")
        for filename in ("package.json", "package-lock.json"):
            shutil.copyfile(ROOT / filename, project / filename)
        shutil.copytree(ROOT / "compiler/fixtures", project / "compiler/fixtures")
        for copy in json.loads((ROOT / "compiler/fixtures/install-manifest.json").read_text())["copies"]:
            shutil.copytree(ROOT / copy["from"], project / copy["to"], dirs_exist_ok=True)
        bundle = work / "archive/destino.js"
        bundle.parent.mkdir()
        before = time.monotonic()
        compiled = subprocess.run([str(compiler), str(project), "project/destino.ts", str(bundle)], capture_output=True, text=True, timeout=90)
        (work / "compiler.log").write_text(compiled.stdout + compiled.stderr)
        check("SDK npm y Zod compilados con esbuild WASM dentro de JSC", compiled.returncode == 0 and bundle.exists(), compiled.stderr[-1500:])
        metrics.update(compileSeconds=round(time.monotonic() - before, 3), bundleBytes=bundle.stat().st_size,
                       sha256=hashlib.sha256(bundle.read_bytes()).hexdigest())
        check("Credencial ausente del paquete JavaScript", TOKEN.encode() not in bundle.read_bytes())

        def run(name, action, expected=True, bundle_override=None, **values):
            data = {"action": action, "origin": origin, **values}
            input_path, output_path = work / f"{name}.input.json", work / f"{name}.output.json"
            input_path.write_text(json.dumps(data))
            result = subprocess.run([str(runtime), str(bundle_override or bundle), str(input_path), str(output_path), origin], capture_output=True, text=True, timeout=45)
            (work / f"{name}.log").write_text(result.stdout + result.stderr)
            check(f"{name}: resultado {'correcto' if expected else 'fallo esperado'}", output_path.exists(), result.stderr[-2000:])
            output = json.loads(output_path.read_text())
            check(f"{name}: estado", output.get("ok") is expected and result.returncode == (0 if expected else 1), output.get("error"))
            check(f"{name}: JS y diagnóstico sin credencial", TOKEN not in output_path.read_text() + result.stdout + result.stderr)
            return output

        fixture_bundle = work / "archive/resolution.js"
        fixture = subprocess.run([str(compiler), str(project), "compiler/fixtures/entry.ts", str(fixture_bundle)], capture_output=True, text=True, timeout=90)
        check("Subruta npm y dependencia transitiva anidada compilan", fixture.returncode == 0, fixture.stderr[-1500:])
        fixture_result = run("resolution", "inspect", bundle_override=fixture_bundle)
        check("ESM, CommonJS, exports condicionales y JSON ejecutan en JSC", fixture_result["result"] == {"answer": 42} and not state.requests)
        unsupported = subprocess.run([str(compiler), str(project), "compiler/fixtures/nodefs.ts", str(work / "unsupported.js")], capture_output=True, text=True, timeout=90)
        check("Dependencia de node:fs se rechaza al compilar", unsupported.returncode != 0 and "node:fs" in unsupported.stderr)

        before = len(state.requests)
        inspected = run("schema", "inspect")
        check("Destino Zod inspeccionado sin HTTP", len(state.requests) == before and "parentId" in inspected["result"]["schema"]["properties"])
        published = run("publish", "publish", title="Primera nota sintética")
        receipt = published["result"]["receipt"]
        check("Página y bloques creados; recibo guardado", len(state.pages) == 1 and len(state.pages[receipt["pageId"]]["blocks"]) == 2 and published["checkpoints"] == [receipt])

        (project / "project/destino.ts").write_text("export async function run( { this is broken")
        broken = subprocess.run([str(compiler), str(project), "project/destino.ts", str(work / "rejected.js")], capture_output=True, text=True, timeout=90)
        (work / "broken-compiler.log").write_text(broken.stdout + broken.stderr)
        check("Error de compilación conserva paquete anterior", broken.returncode != 0 and not (work / "rejected.js").exists() and hashlib.sha256(bundle.read_bytes()).hexdigest() == metrics["sha256"])
        # Only our scratch copy is deleted. No live project files are touched.
        shutil.rmtree(project)
        check("Fuentes y node_modules retirados del proyecto de prueba", not project.exists())
        updated = run("update-archived", "update", receipt=receipt, title="Título corregido")
        check("Regeneración con paquete archivado y paginación", len(state.pages) == 1 and updated["result"]["removed"] == 2 and updated["result"]["receipt"] == receipt and any(r["query"].get("start_cursor") for r in state.requests))
        check("Los bloques reflejan la corrección", "Título corregido" in json.dumps(state.pages[receipt["pageId"]], ensure_ascii=False))
        upload = run("upload", "upload", receipt=receipt, attachUpload=True)
        saved = state.uploads[upload["result"]["uploadId"]]
        with wave.open(io.BytesIO(bytes(saved["bytes"])), "rb") as wav:
            valid_audio = wav.getnchannels() == 1 and wav.getsampwidth() == 2 and wav.getframerate() == 8000 and wav.getnframes() == 80 and wav.readframes(80) == bytes(160)
        check("SDK envía multipart con WAV binario sintético íntegro", saved["status"] == "uploaded" and saved["filename"] == "escriba-poc.wav" and saved["contentType"] == "audio/wav" and valid_audio)
        check("El SDK adjunta el audio publicado", any(b.get("type") == "audio" and b["audio"]["file_upload"]["id"] == saved["id"] for b in state.pages[receipt["pageId"]]["blocks"]))

        security = run("security", "security", authorizationProbe="not-a-real-token")["result"]["checks"]
        check("Origen ajeno, Authorization y redirección rechazados", all(security[key]["rejected"] for key in ("outside", "authorization", "redirect")))
        check("Cabeceras sensibles y eco literal ocultos", all(security["headers"].values()))
        check("No se siguió la redirección ni salió Authorization del JS", not any(r["path"] in ("/poc/redirect-target", "/v1/users/me") for r in state.requests))
        before = len(state.requests)
        run("revoked", "update", expected=False, receipt=receipt, revoked=True)
        check("Cuenta revocada impide HTTP incluso con paquete archivado", len(state.requests) == before)

        run("remove-archived", "remove", receipt=receipt)
        check("Retirada con mismo localizador y paquete archivado", state.pages[receipt["pageId"]]["archived"])

        state.fail_next = "append"
        partial = run("partial", "publish", expected=False)
        check("Fallo después de crear conserva el recibo", len(partial["checkpoints"]) == 1)
        recover_receipt = partial["checkpoints"][0]
        before = len(state.pages)
        run("recover", "update", receipt=recover_receipt)
        check("Recuperación usa la página creada sin duplicarla", len(state.pages) == before and len(state.pages[recover_receipt["pageId"]]["blocks"]) == 2)

        crash_input, crash_output = work / "crash.input.json", work / "crash.output.json"
        crash_input.write_text(json.dumps({"action": "publish", "origin": origin, "crashAfterCheckpoint": True}))
        crashed = subprocess.run([str(runtime), str(bundle), str(crash_input), str(crash_output), origin], capture_output=True, text=True, timeout=45)
        journal = Path(str(crash_output) + ".checkpoints.json")
        check("Cierre del proceso tras crear conserva journal", crashed.returncode == 86 and journal.exists() and not crash_output.exists(), crashed.stderr)
        crash_receipt = json.loads(journal.read_text())[-1]
        before = len(state.pages)
        run("recover-crash", "update", receipt=crash_receipt)
        check("Proceso nuevo recupera tras cierre sin página duplicada", len(state.pages) == before and len(state.pages[crash_receipt["pageId"]]["blocks"]) == 2)

        state.fail_next = "rate-limit"
        before = len(state.requests)
        run("rate-limit", "publish", expected=False)
        check("429 propagado sin reintento automático", len(state.requests) - before == 1)

        state.fail_next = "uncertain-create"
        before, pages_before = len(state.requests), len(state.pages)
        uncertain = run("uncertain", "publish", expected=False)
        check("Creación incierta no se repite a ciegas", len(state.requests) - before == 1 and len(state.pages) == pages_before + 1 and uncertain["checkpoints"] == [])
        check("Todas las peticiones recibidas fueron autenticadas por Swift", all(r["authenticated"] for r in state.requests))
        check("El paquete archivado conserva su huella", hashlib.sha256(bundle.read_bytes()).hexdigest() == metrics["sha256"])
        completed = True
    finally:
        server.shutdown()
        server.server_close()
        metrics["totalSeconds"] = round(time.monotonic() - started, 3)
        sources = {path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest() for path in ("run.py", "compiler/compile.swift", "runtime/run.swift", "runtime/prelude.js", "project/destino.ts", "package-lock.json")}
        report = {"prototype": True, "completed": completed, "checks": checks, "metrics": metrics, "sources": sources,
                  "requests": state.requests, "pages": state.pages, "uploads": state.uploads}
        (work / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
        (scratch / "latest.txt").write_text(str(work) + "\n")
        print(f"Artifacts: {work}", flush=True)
    print(f"SUCCESS: {len(checks)} comprobaciones, {metrics['totalSeconds']} s", flush=True)


if __name__ == "__main__":
    main()
