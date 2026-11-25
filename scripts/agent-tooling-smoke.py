#!/usr/bin/env python3
"""Smoke-test built record/Azure/Kubernetes artifacts, without cloud access.

Usage: python3 -I scripts/agent-tooling-smoke.py --record <package> --azure <package>
         --kubernetes <package>

Oracles: literal recording input; MCP initialize/tools/list; read-only tool
annotations; and a fake Kubernetes API which returns a known Namespace but must
never receive a Secret read. No user kubeconfig or cloud credentials are used.
"""

import argparse
import json
import os
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Mcp:
    def __init__(self, command, env=None):
        self.proc = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, text=True, env=env)
        self.responses = queue.Queue()
        self.sequence = 0

        def read():
            for line in self.proc.stdout:
                try:
                    self.responses.put(json.loads(line))
                except json.JSONDecodeError:
                    self.responses.put({"unexpected_stdout": line[:160]})
            self.responses.put({"eof": True})

        threading.Thread(target=read, daemon=True).start()
        try:
            self.call("initialize", {"protocolVersion": "2025-03-26", "capabilities": {},
                                     "clientInfo": {"name": "agent-tooling-smoke", "version": "1"}})
            self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        except BaseException:
            self.close()
            raise

    def send(self, value):
        self.proc.stdin.write(json.dumps(value) + "\n")
        self.proc.stdin.flush()

    def call(self, method, params):
        self.sequence += 1
        self.send({"jsonrpc": "2.0", "id": self.sequence, "method": method, "params": params})
        while True:
            reply = self.responses.get(timeout=40)
            if "eof" in reply or "unexpected_stdout" in reply:
                raise AssertionError(f"not an MCP response: {reply}")
            if reply.get("id") != self.sequence:
                continue  # server notification
            assert "error" not in reply, reply.get("error")
            return reply["result"]

    def close(self):
        self.proc.terminate()
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(timeout=5)
        self.proc.stdin.close()
        self.proc.stdout.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ("record", "azure", "kubernetes"):
        parser.add_argument("--" + arg, required=True, type=Path)
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="agent-tooling-") as temp:
        root = Path(temp)
        target = root / "recordings.jsonl"
        env = {**os.environ, "AI_RECORDINGS_FILE": str(target)}
        result = subprocess.run([args.record / "bin/record", '{"kind":"artifact-smoke"}'],
                                env=env, capture_output=True, text=True, timeout=15)
        assert result.returncode == 0, result.stderr
        rows = [json.loads(line) for line in target.read_text().splitlines()]
        assert len(rows) == 1 and rows[0]["kind"] == "artifact-smoke", rows
        assert rows[0].get("ts") and rows[0].get("pwd"), rows
        print("PASS record: packaged command appended the literal input once")

        azure = Mcp([args.azure / "bin/azmcp", "server", "start", "--read-only"],
                    {**os.environ, "AZURE_MCP_COLLECT_TELEMETRY": "false",
                     "AZURE_TOKEN_CREDENTIALS": "AzureCliCredential"})
        try:
            names = {tool["name"] for tool in azure.call("tools/list", {})["tools"]}
            assert {"subscription_list", "group_list"} <= names, names
            print(f"PASS azure: real binary initialized and exposed {len(names)} tools")
        finally:
            azure.close()

        requests = []

        class Api(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                path = self.path.split("?")[0]
                requests.append(path)
                data = {
                    "/api": {"kind": "APIVersions", "apiVersion": "v1", "versions": ["v1"]},
                    "/apis": {"kind": "APIGroupList", "apiVersion": "v1", "groups": []},
                    "/api/v1": {"kind": "APIResourceList", "apiVersion": "v1", "groupVersion": "v1",
                                "resources": [
                                    {"name": "namespaces", "singularName": "namespace", "namespaced": False,
                                     "kind": "Namespace", "verbs": ["get", "list"]},
                                    {"name": "secrets", "singularName": "secret", "namespaced": True,
                                     "kind": "Secret", "verbs": ["get", "list"]},
                                ]},
                    "/api/v1/namespaces/smoke-test": {"kind": "Namespace", "apiVersion": "v1",
                                                         "metadata": {"name": "smoke-test"}},
                    # If the guard fails this response would be returned to the
                    # model. The request assertion below catches that too.
                    "/api/v1/namespaces/default/secrets": {"kind": "SecretList", "apiVersion": "v1",
                                                           "items": []},
                }.get(path)
                self.send_response(200 if data is not None else 404)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(data or {"error": "unknown fake API path"}).encode())

        server = ThreadingHTTPServer(("127.0.0.1", 0), Api)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        kubeconfig = root / "kubeconfig"
        kubeconfig.write_text(json.dumps({
            "apiVersion": "v1", "kind": "Config", "current-context": "smoke",
            "clusters": [{"name": "smoke", "cluster": {"server": f"http://127.0.0.1:{server.server_port}"}}],
            "contexts": [{"name": "smoke", "context": {"cluster": "smoke", "user": "smoke"}}],
            "users": [{"name": "smoke", "user": {}}],
        }))
        kube = None
        try:
            kube = Mcp([args.kubernetes / "bin/kubernetes-mcp-server", "--config",
                        args.kubernetes / "share/kubernetes-mcp-server/config.toml"],
                       {**os.environ, "KUBECONFIG": str(kubeconfig)})
            tools = kube.call("tools/list", {})["tools"]
            names = {tool["name"] for tool in tools}
            assert {"resources_get", "resources_list", "helm_list"} <= names, names
            assert all(tool.get("annotations", {}).get("readOnlyHint") is True for tool in tools)
            assert not ({"pods_exec", "pods_run", "pods_delete", "resources_delete",
                         "resources_create_or_update", "resources_scale", "helm_install", "helm_uninstall"} & names)
            print(f"PASS kubernetes: {len(names)} read-only tools; no exec, run, write or delete tools")
            namespace = kube.call("tools/call", {"name": "resources_get", "arguments": {
                "context": "smoke", "apiVersion": "v1", "kind": "Namespace", "name": "smoke-test"}})
            assert not namespace.get("isError"), namespace
            assert "smoke-test" in json.dumps(namespace), namespace
            assert "/api/v1/namespaces/smoke-test" in requests, requests
            print("PASS kubernetes: positive control read the fake Namespace")
            secret = kube.call("tools/call", {"name": "resources_list", "arguments": {
                "context": "smoke", "apiVersion": "v1", "kind": "Secret", "namespace": "default"}})
            assert secret.get("isError") is True, secret
            assert "denied" in json.dumps(secret).lower() or "not allowed" in json.dumps(secret).lower(), secret
            assert "/api/v1/namespaces/default/secrets" not in requests, requests
            print("PASS kubernetes: Secret refused without a Secret request reaching the API")
        finally:
            if kube is not None:
                kube.close()
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    main()
