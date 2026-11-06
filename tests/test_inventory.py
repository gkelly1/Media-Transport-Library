from __future__ import annotations

import subprocess
from pathlib import Path

from mxlperf.common import node_login

ROOT = Path(__file__).resolve().parents[1]

INVENTORY = {
    "LAB_SSH_USER": "gta",
    "CONTROL_PLANE_HOST": "10.0.0.11",
    "WORKER_1_HOST": "10.0.0.12",
    "WORKER_1_USER": "root",
}


def _bash(script: str, **env: str) -> subprocess.CompletedProcess[str]:
    prelude = f"source {ROOT}/scripts/lib/remote-admin.sh\nsource {ROOT}/scripts/lib/inventory.sh\n"
    return subprocess.run(
        ["bash", "-c", prelude + script],
        text=True, capture_output=True, env={"PATH": "/usr/bin:/bin"} | env,
    )


def test_node_login_defaults_to_the_shared_user() -> None:
    assert node_login(INVENTORY, "control-plane") == ("gta", "10.0.0.11")


def test_node_login_prefers_the_per_node_user() -> None:
    assert node_login(INVENTORY, "worker-1") == ("root", "10.0.0.12")


def test_node_login_reports_missing_parts_as_empty() -> None:
    assert node_login({"WORKER_1_HOST": "10.0.0.12"}, "worker-1") == ("", "10.0.0.12")
    assert node_login({"LAB_SSH_USER": "gta"}, "worker-1") == ("gta", "")


def test_shell_target_uses_the_per_node_user_and_falls_back_to_the_default() -> None:
    env = {"LAB_SSH_USER": "gta", "WORKER_1_USER": "root",
           "CONTROL_PLANE_HOST": "10.0.0.11", "WORKER_1_HOST": "10.0.0.12"}
    result = _bash('lab_target_of control-plane; echo; lab_target_of worker-1', **env)
    assert result.stdout.splitlines() == ["gta@10.0.0.11", "root@10.0.0.12"]


def test_shell_sudo_mode_follows_each_nodes_own_login() -> None:
    env = {"LAB_SSH_USER": "gta", "WORKER_1_USER": "root",
           "CONTROL_PLANE_HOST": "10.0.0.11", "WORKER_1_HOST": "10.0.0.12"}
    script = (
        'lab_resolve_node control-plane; echo "$SSH_USER sudo=[$LAB_REMOTE_SUDO]"\n'
        'lab_resolve_node worker-1; echo "$SSH_USER sudo=[$LAB_REMOTE_SUDO] host=$HOST"\n'
    )
    result = _bash(script, **env)
    assert result.stdout.splitlines() == ["gta sudo=[sudo]", "root sudo=[] host=10.0.0.12"]


def test_shell_names_the_missing_login_key() -> None:
    result = _bash("lab_target_of worker-1", WORKER_1_HOST="10.0.0.12")
    assert result.returncode == 2
    assert "set WORKER_1_USER or LAB_SSH_USER" in result.stderr
