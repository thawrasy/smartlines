"""One version for each release (independent review, round 9, MAN P1; docs/operations/RELEASES.md).

VERSION names the release; the schema files record the same version, a tag that is not v<VERSION> is refused, and a
production server refuses a checkout that does not stand on that tag.
"""
import pathlib
import shutil
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]


def run(*cmd, cwd=None):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)


def test_version_and_schema_files_agree_and_a_wrong_tag_is_refused():
    ok = run(sys.executable, str(REPO / "scripts" / "check_release.py"))
    assert ok.returncode == 0, ok.stderr
    version = (REPO / "VERSION").read_text().strip()
    assert run(sys.executable, str(REPO / "scripts" / "check_release.py"), "--tag", f"v{version}").returncode == 0
    wrong = run(sys.executable, str(REPO / "scripts" / "check_release.py"), "--tag", "v1.50.0")
    assert wrong.returncode == 1 and f"is not v{version}" in wrong.stderr


def test_a_version_no_schema_file_records_fails_the_check(tmp_path):
    (tmp_path / "scripts").mkdir()
    shutil.copy(REPO / "scripts" / "check_release.py", tmp_path / "scripts")
    (tmp_path / "db" / "schema").mkdir(parents=True)
    (tmp_path / "db" / "schema" / "0001.sql").write_text(
        "INSERT INTO sys.schema_migration (version, description) VALUES ('1.2.0', 'x');\n")
    (tmp_path / "VERSION").write_text("1.3.0\n")
    r = run(sys.executable, str(tmp_path / "scripts" / "check_release.py"))
    assert r.returncode == 1 and "highest version a schema file records is 1.2.0" in r.stderr


def test_production_refuses_a_checkout_that_is_not_the_release_tag(tmp_path):
    prod = tmp_path / "deploy" / "production"
    prod.mkdir(parents=True)
    shutil.copy(REPO / "deploy" / "production" / "preflight.sh", prod)
    (tmp_path / "deploy" / ".env").write_text("MASSLAK_ENVIRONMENT=production\n")
    (tmp_path / "VERSION").write_text("1.51.0\n")
    git = ["git", "-c", "user.email=ci@test", "-c", "user.name=ci", "-c", "commit.gpgsign=false"]
    for cmd in (["init", "-q"], ["add", "-A"], ["commit", "-qm", "work"]):
        assert run(*git, *cmd, cwd=tmp_path).returncode == 0
    refused = run("bash", str(prod / "preflight.sh"))
    assert "this checkout is not the release v1.51.0" in refused.stdout + refused.stderr
    assert run(*git, "tag", "v1.51.0", cwd=tmp_path).returncode == 0
    tagged = run("bash", str(prod / "preflight.sh"))
    assert "not the release" not in tagged.stdout + tagged.stderr
