"""Verifier trust score -- independent of reporter trust (design doc:
docs/superpowers/specs/2026-09-19-verifier-trust-design.md)."""
from app.db.models import AccuracyFeedback, Report, Sighting, User
from app.services.verifier_trust import (
    BASELINE,
    CORRECT_DELTA,
    WRONG_DELTA,
    report_verdict,
    verifier_payload,
    verifier_score,
    verifier_tier,
)


def _report(db, reporter_id, report_id="r1"):
    r = Report(id=report_id, reporter_id=reporter_id, raw_text="x", lat=0, lng=0)
    db.add(r)
    db.flush()
    return r


def _user(db, phone):
    u = User(name="U", phone=phone, password_hash="!")
    db.add(u)
    db.flush()
    return u


def test_report_verdict_is_none_with_no_feedback(db):
    reporter = _user(db, "081200000101")
    report = _report(db, reporter.id)
    db.commit()
    assert report_verdict(db, report.id) is None


def test_report_verdict_majority_vote_and_tie_goes_to_valid(db):
    reporter = _user(db, "081200000102")
    report = _report(db, reporter.id)
    v1, v2, v3 = (_user(db, f"08120000010{i}") for i in (3, 4, 5))
    db.add_all([
        AccuracyFeedback(report_id=report.id, reporter_id=reporter.id, user_id=v1.id, matches=True, verdict="hoax"),
        AccuracyFeedback(report_id=report.id, reporter_id=reporter.id, user_id=v2.id, matches=True, verdict="valid"),
    ])
    db.commit()
    assert report_verdict(db, report.id) == "valid"  # 1 hoax vs 1 valid -> tie -> valid

    db.add(AccuracyFeedback(report_id=report.id, reporter_id=reporter.id, user_id=v3.id, matches=True, verdict="hoax"))
    db.commit()
    assert report_verdict(db, report.id) == "hoax"  # 2 hoax vs 1 valid -> hoax


def test_verifier_score_skips_unsettled_reports(db):
    reporter = _user(db, "081200000110")
    verifier = _user(db, "081200000111")
    report = _report(db, reporter.id, "r-unsettled")
    db.add(Sighting(report_id=report.id, user_id=verifier.id))
    db.commit()
    score, evaluated = verifier_score(db, verifier.id)
    assert (score, evaluated) == (BASELINE, 0)


def test_verifier_score_rewards_correct_and_penalizes_wrong(db):
    reporter = _user(db, "081200000120")
    verifier = _user(db, "081200000121")
    good_report = _report(db, reporter.id, "r-good")
    bad_report = _report(db, reporter.id, "r-bad")
    other = _user(db, "081200000122")
    db.add_all([
        Sighting(report_id=good_report.id, user_id=verifier.id),
        Sighting(report_id=bad_report.id, user_id=verifier.id),
        AccuracyFeedback(report_id=good_report.id, reporter_id=reporter.id, user_id=other.id,
                         matches=True, verdict="valid"),
        AccuracyFeedback(report_id=bad_report.id, reporter_id=reporter.id, user_id=other.id,
                         matches=True, verdict="hoax"),
    ])
    db.commit()
    score, evaluated = verifier_score(db, verifier.id)
    assert evaluated == 2
    assert score == BASELINE + CORRECT_DELTA + WRONG_DELTA


def test_verifier_score_clamps_to_0_100(db):
    reporter = _user(db, "081200000130")
    verifier = _user(db, "081200000131")
    other = _user(db, "081200000132")
    for i in range(30):  # far more than enough to blow past the clamp in either direction
        report = _report(db, reporter.id, f"r-clamp-{i}")
        db.add(Sighting(report_id=report.id, user_id=verifier.id))
        db.add(AccuracyFeedback(report_id=report.id, reporter_id=reporter.id, user_id=other.id,
                                matches=True, verdict="hoax"))
    db.commit()
    score, evaluated = verifier_score(db, verifier.id)
    assert evaluated == 30
    assert score == 0  # clamped, not negative


def test_verifier_tier_gates_on_evaluated_count_then_score(db):
    reporter = _user(db, "081200000140")
    verifier = _user(db, "081200000141")
    other = _user(db, "081200000142")
    assert verifier_tier(db, verifier.id) == "akun_baru"  # zero evaluated

    for i in range(2):
        report = _report(db, reporter.id, f"r-gate-{i}")
        db.add(Sighting(report_id=report.id, user_id=verifier.id))
        db.add(AccuracyFeedback(report_id=report.id, reporter_id=reporter.id, user_id=other.id,
                                matches=True, verdict="valid"))
    db.commit()
    assert verifier_tier(db, verifier.id) == "akun_baru"  # only 2 evaluated, gate is 3

    report = _report(db, reporter.id, "r-gate-3")
    db.add(Sighting(report_id=report.id, user_id=verifier.id))
    db.add(AccuracyFeedback(report_id=report.id, reporter_id=reporter.id, user_id=other.id,
                            matches=True, verdict="valid"))
    db.commit()
    # 3 correct: score = 50 + 3*2 = 56 -> "baik" (51-75)
    assert verifier_tier(db, verifier.id) == "baik"


def test_verifier_payload_shape(db):
    reporter = _user(db, "081200000150")
    verifier = _user(db, "081200000151")
    db.commit()
    payload = verifier_payload(db, verifier.id)
    assert payload == {"tier": "akun_baru", "label": "Akun Baru", "score": BASELINE}
