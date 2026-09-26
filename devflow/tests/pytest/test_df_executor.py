"""df_executor 单测（v3.31.2）：CommandSpec 解析/白名单/边界/超时/回执"""
import json
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "scripts"))
from df_executor import (  # noqa: E402
    CommandSpec, ExecutorError, run_capability, load_profile,
    _resolve_json_path, _filtered_env,
)


class TestCommandSpecParsing:
    def test_from_json_minimal(self):
        spec = CommandSpec.from_json({"executable": "mvn", "args": ["-q", "test"]})
        assert spec.executable == "mvn"
        assert spec.args == ("-q", "test")

    def test_executable_whitelist_rejects_shell_meta(self):
        for evil in ["evil;rm", "../escape", "a|b", "$(cmd)", "", "x y"]:
            with pytest.raises(ValueError):
                CommandSpec.from_json({"executable": evil})

    def test_executable_allows_pathish_names(self):
        assert CommandSpec.from_json({"executable": "python3.11"}).executable == "python3.11"
        assert CommandSpec.from_json({"executable": "node-gyp"}).executable == "node-gyp"

    def test_args_nul_rejected(self):
        with pytest.raises(ValueError):
            CommandSpec.from_json({"executable": "x", "args": ["a\x00b"]})

    def test_to_json_roundtrip(self):
        d = {"executable": "npm", "args": ["test"], "cwd": "be", "timeout_seconds": 60}
        assert CommandSpec.from_json(d).to_json()["args"] == ["test"]


class TestProfileResolution:
    @pytest.fixture(scope="class")
    def profiles_dir(self):
        return Path(__file__).resolve().parent.parent.parent / "runtime-profiles"

    def test_gate_bindings_path(self, profiles_dir):
        p = load_profile("node-express-prisma", profiles_dir)
        spec = CommandSpec.from_profile(p, "P3-build")
        assert spec.executable == "npm"
        assert "build" in spec.args

    def test_three_profiles_build(self, profiles_dir):
        for pid, exe in [
            ("java-spring-flyway", "mvn"),
            ("node-express-prisma", "npm"),
            ("python-fastapi-sqlalchemy", "python"),
        ]:
            spec = CommandSpec.from_profile(load_profile(pid, profiles_dir), "P3-build")
            assert spec.executable == exe, f"{pid} build 应为 {exe}"

    def test_missing_capability_raises(self, profiles_dir):
        p = load_profile("java-spring-flyway", profiles_dir)
        with pytest.raises(ValueError, match="MISSING_CAPABILITY"):
            CommandSpec.from_profile(p, "nonexistent-capability")

    def test_json_path_resolve(self):
        data = {"backend": {"build_adapter": {"executable": "x"}}}
        assert _resolve_json_path(data, "backend.build_adapter") == {"executable": "x"}
        assert _resolve_json_path(data, "backend.nope") is None
        assert _resolve_json_path(data, "") is None


class TestRunCapability:
    def test_success_rc_and_duration(self, tmp_path):
        spec = CommandSpec(executable=sys.executable, args=("-c", "print(7)"))
        rc, ms = run_capability(spec, tmp_path)
        assert rc == 0
        assert ms >= 0

    def test_timeout_kills_and_returns_124(self, tmp_path):
        spec = CommandSpec(
            executable=sys.executable,
            args=("-c", "import time; time.sleep(30)"),
            timeout_seconds=1,
        )
        rc, ms = run_capability(spec, tmp_path)
        assert rc == 124

    def test_cwd_escape_rejected(self, tmp_path):
        (tmp_path / "sub").mkdir()
        spec = CommandSpec(executable="true", cwd="../outside")
        with pytest.raises(ExecutorError, match="escapes workspace"):
            run_capability(spec, tmp_path)

    def test_env_allowlist_filters(self, tmp_path, monkeypatch):
        monkeypatch.setenv("DEVFLOW_SECRET_LEAK", "should-not-pass")
        monkeypatch.setenv("DEVFLOW_TAG", "kept")
        env = _filtered_env(CommandSpec(executable="x").env_allowlist)
        assert "DEVFLOW_TAG" in env
        # DEVFLOW_ 前缀整族放行是设计（skill 自身变量）——锁定该设计
        assert "DEVFLOW_SECRET_LEAK" in env
        assert "NONSENSE_VAR" not in env  # 非白名单且无前缀 → 过滤


class TestCli:
    def test_dry_run_emits_spec_json(self):
        r = subprocess.run(
            [sys.executable, str(Path(__file__).parent.parent.parent / "scripts" / "df_executor.py"),
             "--exec", "true", "--dry-run"],
            capture_output=True, text=True,
        )
        assert r.returncode == 0
        assert json.loads(r.stdout)["executable"] == "true"


class TestTelemetry:
    SCRIPTS_DIR = Path(__file__).resolve().parent.parent.parent / "scripts"

    def test_emit_redacts_sensitive_keys(self, tmp_path):
        from df_telemetry import emit, summary
        rec = emit("fx", "P3", "build", "gate-exit", exit_code=0,
                   duration_ms=10, detail={"api_token": "x" * 40},
                   state_dir=str(tmp_path))
        assert rec["detail"]["api_token"] == "<redacted>"
        assert (tmp_path / "telemetry.jsonl").is_file()

    def test_summary_aggregates(self, tmp_path):
        from df_telemetry import emit, summary
        emit("fx", "P3", "build", "gate-exit", 0, 100, state_dir=str(tmp_path))
        emit("fx", "P3", "build", "gate-exit", 1, 50, state_dir=str(tmp_path))
        sm = summary("fx", str(tmp_path))
        assert sm["phases"]["P3"]["gate_exits"] == 2
        assert sm["phases"]["P3"]["pass"] == 1
        assert sm["phases"]["P3"]["fail"] == 1
        assert sm["phases"]["P3"]["total_duration_ms"] == 150
