#!/usr/bin/env python3
"""dream_correct: misses are mined from transcripts, judged once, and fixed only in reversible ways; undo restores."""
import datetime as dt
import json
import os
import shutil
import tempfile
import unittest

import dream_correct as D

NOW = dt.datetime(2026, 11, 7, 3, 15).timestamp()


def iso(h_ago):
    return dt.datetime.utcfromtimestamp(NOW - h_ago * 3600).strftime("%Y-%m-%dT%H:%M:%S.000Z")


class Fake(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.d)
        born = D._born
        D._born = lambda p: 0                         # fixture lessons exist before every fixture message
        self.addCleanup(setattr, D, "_born", born)
        self.root = os.path.join(self.d, "projects")
        self.mem = os.path.join(self.d, "memory")
        self.dream = os.path.join(self.d, "dream")
        self.board = os.path.join(self.d, "TODO.md")
        os.makedirs(os.path.join(self.root, "-proj"))
        os.makedirs(self.mem)
        with open(self.board, "w") as fh:
            fh.write("# board\n")
        self.lesson("feedback-run-tests-first.md", "feedback", "Run the tests before saying done",
                    ["shipped without running tests"])
        self.lesson("project-capital-one.md", "project", "Capital One checking is closed", [])
        with open(os.path.join(self.mem, "MEMORY.md"), "w") as fh:
            fh.write("# Memory Index\n\n## Hard Rules\n- rule\n\n## Unfiled (sentinel)\n- [x](x.md): small\n")
        self.transcript([
            {"type": "assistant", "message": {"content": [{"type": "text", "text": "Done, it is shipped."}]}, "timestamp": iso(3)},
            {"type": "user", "message": {"content": "no, you shipped it without running the tests again"}, "timestamp": iso(3)},
            {"type": "user", "isMeta": True, "message": {"content": "skill body"}, "timestamp": iso(3)},
            {"type": "user", "message": {"content": [{"type": "tool_result", "content": "x"}]}, "timestamp": iso(3)},
            {"type": "attachment", "attachment": {"type": "queued_command", "prompt": "capital one is still our live account",
                                                  "origin": {"kind": "human"}}, "timestamp": iso(2)},
            {"type": "user", "message": {"content": "This session is being continued from a previous one"}, "timestamp": iso(2)},
            {"type": "user", "message": {"content": "Here is a note offered by a side agent:\n> the hook fails open"}, "timestamp": iso(1)},
            {"type": "user", "message": {"content": "thanks, go"}, "timestamp": iso(1)},
            {"type": "user", "message": {"content": "an old one"}, "timestamp": iso(40)},
            {"type": "user", "isSidechain": True, "message": {"content": "subagent prompt"}, "timestamp": iso(1)},
        ])

    def lesson(self, name, typ, desc, sigs):
        sig = "".join("    - %s\n" % s for s in sigs)
        with open(os.path.join(self.mem, name), "w") as fh:
            fh.write("---\nname: %s\ndescription: %s\nmetadata:\n  type: %s\n%s---\n\nThe rule.\n" % (
                name[:-3], desc, typ, ("  signatures:\n" + sig) if sigs else ""))

    def transcript(self, rows):
        with open(os.path.join(self.root, "-proj", "s1.jsonl"), "w") as fh:
            for r in rows:
                r.setdefault("sessionId", "abcdef12-0000")
                fh.write(json.dumps(r) + "\n")

    def judge(self, verdicts):
        return lambda prompt, model: json.dumps(verdicts)

    def go(self, verdicts=None, **kw):
        return D.run(hours=24, now=NOW, roots=[self.root], mem=self.mem, index=os.path.join(self.mem, "MEMORY.md"),
                     dream=self.dream, board=self.board, model="test", judge_fn=self.judge(verdicts or []), **kw)

    def forget(self):
        """Clear the judged-messages list (as if new messages arrived) but keep the board ledger."""
        led = os.path.join(self.dream, "correct-ledger.json")
        with open(led) as fh:
            d = json.load(fh)
        d["seen"] = {}
        with open(led, "w") as fh:
            json.dump(d, fh)

    def read(self, p):
        with open(p) as fh:
            return fh.read()


class Mine(Fake):
    def test_only_eddie_and_side_agents_in_the_window(self):
        msgs = D.mine([self.root], NOW - 24 * 3600, NOW)
        self.assertEqual(["no, you shipped it without running the tests again", "capital one is still our live account",
                          "Here is a note offered by a side agent:\n> the hook fails open", "thanks, go"],
                         [m["text"] for m in msgs])
        self.assertEqual(["eddie", "eddie", "side-agent", "eddie"], [m["source"] for m in msgs])
        self.assertEqual("Done, it is shipped.", msgs[0]["before"])

    def test_match_finds_the_lesson_by_its_signature(self):
        msgs = D.mine([self.root], NOW - 24 * 3600, NOW)
        self.assertEqual("feedback-run-tests-first.md", D.match(msgs[0], D.lessons(self.mem))[0])


class Fix(Fake):
    def test_recurrence_logs_evidence_and_signature_and_keeps_the_rule(self):
        rep = self.go([{"i": 0, "kind": "recurred", "lesson": "feedback-run-tests-first.md",
                        "symptom": "said done before tests", "summary": "Called it shipped without running tests."}])
        txt = self.read(os.path.join(self.mem, "feedback-run-tests-first.md"))
        self.assertIn("The rule.", txt)
        self.assertIn("    - said done before tests\n", txt)
        self.assertIn("## Recurrences", txt)
        self.assertIn("- 2026-11-07: Called it shipped without running tests.", txt)
        self.assertEqual(1, len(rep["recurred"]))
        self.assertNotIn("DREAM.g3", self.read(self.board), "one recurrence is not yet a guard candidate")
        self.assertEqual(D.parse_lesson(os.path.join(self.mem, "feedback-run-tests-first.md"))["recurrences"], 1)

    def test_second_recurrence_files_one_g3_row_once(self):
        v = [{"i": 0, "kind": "recurred", "lesson": "feedback-run-tests-first.md", "symptom": "x", "summary": "first"}]
        self.go(v)
        v[0]["summary"] = "second"
        self.forget()
        self.go(v)
        v[0]["summary"] = "third"
        self.forget()
        self.go(v)
        self.assertEqual(1, self.read(self.board).count("DREAM.g3-feedback-run-tests-first"))

    def test_new_lesson_is_a_draft_never_live_memory(self):
        before = sorted(os.listdir(self.mem))
        rep = self.go([{"i": 2, "kind": "new", "lesson": None, "symptom": "hook fails open", "summary": "A hook failed open.",
                        "rule": "Test hooks fail closed.", "why": "A side agent caught it."}])
        self.assertEqual(before, sorted(os.listdir(self.mem)))
        self.assertTrue(rep["new"][0]["draft"].startswith(os.path.join(self.dream, "drafts")))
        self.assertIn("status: draft", self.read(rep["new"][0]["draft"]))

    def test_a_fact_that_contradicts_no_note_stays_in_the_report(self):
        rep = self.go([{"i": 1, "kind": "fact", "lesson": None, "summary": "The page was English from browser translate."}])
        self.assertEqual(1, len(rep["fact"]))
        self.assertEqual("# board\n", self.read(self.board))

    def test_the_message_that_created_a_lesson_is_not_a_recurrence(self):
        D._born = lambda p: NOW                       # the lesson was written after tonight's messages
        rep = self.go([{"i": 0, "kind": "recurred", "lesson": "feedback-run-tests-first.md", "symptom": "x", "summary": "y"}])
        self.assertEqual(([], 1), (rep["recurred"], rep["origin"]))
        self.assertNotIn("Recurrences", self.read(os.path.join(self.mem, "feedback-run-tests-first.md")))

    def test_two_misses_of_one_lesson_in_one_night_make_it_a_guard_candidate(self):
        rep = self.go([{"i": 0, "kind": "recurred", "lesson": "feedback-run-tests-first.md", "symptom": "x", "summary": "one"},
                       {"i": 3, "kind": "recurred", "lesson": "feedback-run-tests-first.md", "symptom": "x", "summary": "two"}])
        self.assertEqual([1, 2], [r["times"] for r in rep["recurred"]])
        self.assertEqual(1, self.read(self.board).count("DREAM.g3-feedback-run-tests-first"))

    def test_a_message_is_judged_once_even_if_the_window_overlaps(self):
        calls = []
        def judge(prompt, model):
            calls.append(prompt.count('"source":'))
            return "[]"
        kw = dict(hours=24, now=NOW, roots=[self.root], mem=self.mem, index=os.path.join(self.mem, "MEMORY.md"),
                  dream=self.dream, board=self.board, model="t", judge_fn=judge)
        self.assertEqual(4, D.run(**kw)["messages"])
        self.assertEqual(0, D.run(**kw)["messages"], "the 3:30 run does not re-judge what a manual run judged")
        self.assertEqual([4], calls)

    def test_fact_goes_to_the_board_once_and_memory_is_untouched(self):
        v = [{"i": 1, "kind": "fact", "lesson": "project-capital-one.md", "summary": "Capital One is still the live operating account."}]
        before = self.read(os.path.join(self.mem, "project-capital-one.md"))
        self.go(v)
        self.forget()
        self.go(v)
        self.assertEqual(1, self.read(self.board).count("Capital One is still the live operating account"))
        self.assertEqual(before, self.read(os.path.join(self.mem, "project-capital-one.md")))

    def test_noise_changes_nothing_and_a_broken_judge_still_runs_hygiene(self):
        rep = self.go([{"i": 3, "kind": "noise"}])
        self.assertEqual((0, 1), (rep["misses"], rep["noise"]))
        self.forget()
        bad = D.run(hours=24, now=NOW, roots=[self.root], mem=self.mem, index=os.path.join(self.mem, "MEMORY.md"),
                    dream=self.dream, board=self.board, model="t", judge_fn=lambda p, m: "no json here")
        self.assertTrue(any(e.startswith("judge ") for e in bad["errors"]))
        self.assertTrue(os.path.exists(os.path.join(self.dream, "correct-2026-11-07.md")))

    def test_dry_run_writes_nothing(self):
        before = {f: self.read(os.path.join(self.mem, f)) for f in os.listdir(self.mem)}
        self.go([{"i": 0, "kind": "recurred", "lesson": "feedback-run-tests-first.md", "symptom": "x", "summary": "y"}], dry=True)
        self.assertEqual(before, {f: self.read(os.path.join(self.mem, f)) for f in os.listdir(self.mem)})
        self.assertFalse(os.path.exists(self.dream))
        self.assertEqual("# board\n", self.read(self.board))


class Promote(Fake):
    V = {"i": 2, "kind": "new", "lesson": None, "symptom": "hook fails open on error",
         "summary": "A guard hook failed open.", "rule": "Guard hooks must fail closed.", "why": "A side agent caught it."}

    def test_a_draft_that_happens_again_becomes_a_live_lesson_with_both_dates(self):
        self.go([self.V])
        self.assertFalse([f for f in os.listdir(self.mem) if "hook-fails-open" in f], "first time: draft only")
        later = NOW + 2 * 86400
        rep = D.run(hours=24, now=later, roots=[self.root], mem=self.mem, index=os.path.join(self.mem, "MEMORY.md"),
                    dream=self.dream, board=self.board, model="t", judge_fn=lambda p, m: "[]")
        self.assertEqual([], rep["promoted"], "no miss tonight: nothing promoted")
        os.utime(os.path.join(self.root, "-proj", "s1.jsonl"))
        self.forget()
        rep = D.run(hours=24 * 3, now=later, roots=[self.root], mem=self.mem, index=os.path.join(self.mem, "MEMORY.md"),
                    dream=self.dream, board=self.board, model="t", judge_fn=self.judge([dict(self.V, i=0, summary="It failed open again.")]))
        self.assertEqual(1, len(rep["promoted"]))
        live = os.path.join(self.mem, rep["promoted"][0]["lesson"])
        txt = self.read(live)
        self.assertNotIn("status: draft", txt)
        self.assertIn("- 2026-11-07: first seen (drafted)", txt)
        self.assertIn("- 2026-11-09: It failed open again.", txt)
        self.assertIn(rep["promoted"][0]["lesson"], self.read(os.path.join(self.mem, "MEMORY.md")))
        self.assertEqual([], D.waiting_drafts(self.dream), "the draft is marked promoted, not matched again")
        self.assertIsNotNone(D.parse_lesson(live), "the live lesson parses like any other")

    def test_side_agent_only_patterns_never_go_live(self):
        side = dict(self.V, i=2)                     # message 2 is the side-agent note
        self.go([side])
        self.forget()
        rep = self.go([side])
        self.assertEqual([], rep["promoted"])
        self.assertEqual(1, len(rep["new"]))

    def test_a_draft_that_never_recurs_expires_and_is_kept(self):
        self.go([self.V])
        rep = D.run(hours=24, now=NOW + 22 * 86400, roots=[self.root], mem=self.mem, index=os.path.join(self.mem, "MEMORY.md"),
                    dream=self.dream, board=self.board, model="t", judge_fn=lambda p, m: "[]")
        self.assertEqual(1, rep["expired"])
        drafts = os.listdir(os.path.join(self.dream, "drafts"))
        self.assertEqual(1, len(drafts))
        self.assertIn("status: expired", self.read(os.path.join(self.dream, "drafts", drafts[0])))


class Section(Fake):
    def test_the_dream_gets_a_plain_what_went_wrong_section(self):
        rep = self.go([{"i": 0, "kind": "recurred", "lesson": "feedback-run-tests-first.md", "symptom": "x",
                        "summary": "Called it shipped without tests."},
                       {"i": 1, "kind": "fact", "summary": "Capital One is still live."}])
        with open(os.path.join(self.dream, "misses-2026-11-07.json")) as fh:
            txt = D.section(json.load(fh))
        self.assertIn("## What went wrong", txt)
        self.assertIn("did not hold (feedback-run-tests-first, x1): Called it shipped without tests.", txt)
        self.assertIn("You set a fact straight: Capital One is still live.", txt)
        self.assertEqual("", D.section({"messages": 0}))


class Index(Fake):
    def big_index(self):
        lines = ["# Memory Index", "", "## Hard Rules", "- [keep](k.md): hard rule stays", "", "## Unfiled (sentinel)",
                 "- **Filed 10/31 to 11/02** (sub-index: `_dispatch_unfiled_2026_11.md`, 15 lines): pointer stays"]
        for i in range(120):
            lines.append("- [Lesson %d (11/%02d)](l%d.md): %s" % (i, 1 + i % 6, i, "x" * 200))
        with open(os.path.join(self.mem, "MEMORY.md"), "w") as fh:
            fh.write("\n".join(lines) + "\n")

    def test_index_is_brought_under_the_limit_oldest_first_and_nothing_is_lost(self):
        self.big_index()
        before = self.read(os.path.join(self.mem, "MEMORY.md"))
        rep = self.go()
        after = self.read(os.path.join(self.mem, "MEMORY.md"))
        self.assertLessEqual(len(after.encode()), D.INDEX_LIMIT)
        self.assertGreater(rep["index_moved"], 0)
        self.assertIn("hard rule stays", after)
        self.assertIn("pointer stays", after)
        self.assertIn("Moved off the index 2026-11-07", after)
        disp = self.read(os.path.join(self.mem, "_dispatch_unfiled_2026_11.md"))
        for ln in before.splitlines():
            if ln.startswith("- [Lesson"):
                self.assertTrue(ln in after or ln in disp, ln[:30])
        self.assertIn("(11/01)", disp.splitlines()[-1] + disp)          # oldest went first
        self.assertNotIn("(11/01)", after)

    def test_undo_restores_the_night_exactly(self):
        self.big_index()
        before = self.read(os.path.join(self.mem, "MEMORY.md"))
        self.go([{"i": 0, "kind": "recurred", "lesson": "feedback-run-tests-first.md", "symptom": "x", "summary": "y"}])
        D.undo("2026-11-07", root=self.dream)
        self.assertEqual(before, self.read(os.path.join(self.mem, "MEMORY.md")))
        self.assertNotIn("Recurrences", self.read(os.path.join(self.mem, "feedback-run-tests-first.md")))
        self.assertFalse(os.path.exists(os.path.join(self.mem, "_dispatch_unfiled_2026_11.md")),
                         "a dispatch file the night created is set aside")
        self.assertEqual("# board\n", self.read(self.board))


class Repeats(Fake):
    def test_a_file_flagged_three_nights_gets_one_board_row(self):
        os.makedirs(self.dream)
        for day in ("04", "05", "06"):
            with open(os.path.join(self.dream, "synthesis-2026-11-%s.md" % day), "w") as fh:
                fh.write("## Stale\n- **`feedback_two_main_lines.md` is stale.** `MEMORY.md` too.\n")
        rep = self.go()
        self.assertEqual(["feedback_two_main_lines.md"], rep["repeat_rows"])
        self.go()
        self.assertEqual(1, self.read(self.board).count("DREAM.repeat-feedback_two_main_lines"))
        self.assertNotIn("DREAM.repeat-MEMORY", self.read(self.board))


if __name__ == "__main__":
    unittest.main()
