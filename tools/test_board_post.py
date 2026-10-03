"""board-post.sh tests against a scratch DB. Run: /usr/bin/python3 -m pytest ~/.hydra/tools/test_board_post.py -q"""
import os, sqlite3, subprocess
import pytest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "board-post.sh")


@pytest.fixture
def db(tmp_path):
    p = tmp_path / "hydra.db"
    con = sqlite3.connect(p)
    con.execute("""CREATE TABLE agent_board (id INTEGER PRIMARY KEY AUTOINCREMENT, channel TEXT NOT NULL,
        agent TEXT NOT NULL, message TEXT NOT NULL, parent_id INTEGER, tags TEXT,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)""")
    con.commit(); con.close()
    return str(p)


def post(db, *args):
    return subprocess.run(["bash", SCRIPT, *args], capture_output=True, text=True, env=dict(os.environ, HYDRA_DB=db))


def rows(db):
    return sqlite3.connect(db).execute("SELECT channel, agent, message, parent_id, tags FROM agent_board").fetchall()


def test_posts_and_returns_id(db):
    p = post(db, "coordination", "observer", "Vox is stale (230d)", "--tags", "critical,auto")
    assert p.returncode == 0 and p.stdout.strip() == "1"
    assert rows(db) == [("coordination", "observer", "Vox is stale (230d)", None, "critical,auto")]


def test_quotes_and_sql_are_stored_literally(db):
    msg = "it's'); DROP TABLE agent_board; --"
    assert post(db, "ideas", "manual", msg).returncode == 0
    assert rows(db)[0][2] == msg


def test_rejects_bad_identifiers_and_parent(db):
    assert post(db, "ideas'); --", "manual", "x").returncode == 1
    assert post(db, "ideas", "Manual Agent", "x").returncode == 1
    assert post(db, "ideas", "manual", "x", "--parent", "1; DROP TABLE agent_board").returncode == 1
    assert post(db, "ideas", "manual", "x", "--dedupe-hours", "1h").returncode == 1
    assert rows(db) == []


def test_reply_parent(db):
    post(db, "builds", "manual", "root")
    assert post(db, "builds", "manual", "child", "--parent", "1").returncode == 0
    assert rows(db)[1][3] == 1


def test_dedupe_skips_paraphrase_of_recent_post(db):
    a = "Five projects dormant/stale: Vox (230d), parallax-mobile (211d), Kalshi Bot (186d), Claude Code Sounds (167d), Pause (153d archived/deployed)"
    b = "Multiple stale projects identified: Vox (230d), parallax-mobile (211d), Kalshi Bot (186d), Claude Code Sounds (167d), Pause (153d archived/deployed)"
    assert post(db, "coordination", "observer", a, "--dedupe-hours", "24").stdout.strip() == "1"
    p = post(db, "coordination", "observer", b, "--dedupe-hours", "24")
    assert p.returncode == 0 and p.stdout.startswith("skipped: near-duplicate of #1")
    assert len(rows(db)) == 1


def test_dedupe_allows_new_finding_other_agent_or_old_post(db):
    post(db, "coordination", "observer", "Vox is stale (230d)", "--dedupe-hours", "24")
    assert post(db, "coordination", "observer", "Disk usage at 94 percent on the boot volume", "--dedupe-hours", "24").stdout.strip() == "2"
    assert post(db, "coordination", "planner", "Vox is stale (230d)", "--dedupe-hours", "24").stdout.strip() == "3"
    con = sqlite3.connect(db); con.execute("UPDATE agent_board SET created_at=datetime('now','-30 hours') WHERE id=1"); con.commit()
    assert post(db, "coordination", "observer", "Vox is stale (230d)", "--dedupe-hours", "24").stdout.strip() == "4"


def test_without_flag_duplicates_still_post(db):
    post(db, "health", "manual", "same")
    assert post(db, "health", "manual", "same").stdout.strip() == "2"
