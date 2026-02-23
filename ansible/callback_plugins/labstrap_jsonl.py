# labstrap structured stdout callback
from __future__ import annotations

import json
import os
from datetime import datetime, timezone

from ansible.plugins.callback import CallbackBase


def _ts() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _infer_operation(task_name: str, action: str) -> str:
    name = (task_name or "").lower()
    module = (action or "").lower()

    if any(k in name for k in ("download", "fetch", "get_url", "curl")):
        return "download"
    if any(k in name for k in ("install", "upgrade", "package", "apt", "pip", "brew")):
        return "install"
    if any(k in name for k in ("configure", "set", "lineinfile", "copy", "template", "symlink", "link")):
        return "configure"
    if any(k in name for k in ("check", "verify", "assert", "status", "validate")):
        return "verify"

    if module in {"apt", "pip", "package", "homebrew", "dnf", "yum", "apt_key"}:
        return "install"
    if module in {"copy", "template", "lineinfile", "replace", "file", "user", "group"}:
        return "configure"
    if module in {"get_url", "uri"}:
        return "download"

    return "step"


class CallbackModule(CallbackBase):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = "stdout"
    CALLBACK_NAME = "labstrap_jsonl"

    def __init__(self) -> None:
        super().__init__()
        self.log_file = os.environ.get("LABSTRAP_LOG_FILE", "")
        self.command = os.environ.get("LABSTRAP_LOG_COMMAND", "")
        self.phase = os.environ.get("LABSTRAP_PHASE", "")

    def _emit(self, payload: dict) -> None:
        payload.setdefault("timestamp", _ts())
        payload.setdefault("source", "ansible")
        payload.setdefault("command", self.command)
        payload.setdefault("phase", self.phase)

        line = json.dumps(payload, separators=(",", ":"), sort_keys=True)
        self._display.display(line)

        if self.log_file:
            try:
                with open(self.log_file, "a", encoding="utf-8") as fp:
                    fp.write(line + "\n")
            except OSError:
                pass

    def _event_from_result(self, status: str, result) -> dict:
        task = result._task
        host = result._host.get_name()
        res = result._result or {}

        payload = {
            "event": "ansible.task",
            "status": status,
            "task": task.get_name().strip(),
            "module": task.action,
            "operation": _infer_operation(task.get_name(), task.action),
            "host": host,
            "changed": bool(res.get("changed", False)),
        }

        if "msg" in res and isinstance(res["msg"], str):
            payload["msg"] = res["msg"]
        if status in {"failed", "unreachable"}:
            if "stderr" in res and isinstance(res["stderr"], str):
                payload["stderr"] = res["stderr"]
            if "stdout" in res and isinstance(res["stdout"], str):
                payload["stdout"] = res["stdout"]

        return payload

    def v2_playbook_on_start(self, playbook) -> None:
        self._emit(
            {
                "event": "ansible.playbook_start",
                "playbook": playbook._file_name,
            }
        )

    def v2_playbook_on_play_start(self, play) -> None:
        self._emit(
            {
                "event": "ansible.play_start",
                "play": play.get_name().strip(),
            }
        )

    def v2_playbook_on_task_start(self, task, is_conditional) -> None:
        self._emit(
            {
                "event": "ansible.task_start",
                "task": task.get_name().strip(),
                "module": task.action,
                "operation": _infer_operation(task.get_name(), task.action),
            }
        )

    def v2_runner_on_ok(self, result, **kwargs) -> None:
        self._emit(self._event_from_result("ok", result))

    def v2_runner_on_failed(self, result, ignore_errors=False) -> None:
        payload = self._event_from_result("failed", result)
        payload["ignore_errors"] = bool(ignore_errors)
        self._emit(payload)

    def v2_runner_on_unreachable(self, result) -> None:
        self._emit(self._event_from_result("unreachable", result))

    def v2_runner_on_skipped(self, result) -> None:
        self._emit(self._event_from_result("skipped", result))

    def v2_playbook_on_stats(self, stats) -> None:
        summary = {}
        for host in sorted(stats.processed.keys()):
            summary[host] = stats.summarize(host)

        self._emit(
            {
                "event": "ansible.playbook_stats",
                "summary": summary,
            }
        )
