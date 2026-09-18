"""End-to-end: register -> report -> confirm -> batch alarms -> accept/reject ->
escalation -> arrival -> collective confirmation -> experience & trust."""
from datetime import timedelta

from sqlalchemy import select

from app.db.models import (
    Assignment,
    Need,
    Notification,
    Offer,
    Participant,
    Report,
    Skill,
    User,
    VolunteerProfile,
    VolunteerSkill,
    utcnow,
)
from app.services import confirmation, dispatch
from app.services.geo import offset_point

SITE = (-6.1470, 106.8055)
TEXT = "Kebakaran rumah di Gang Mawar RT 05, ada lansia terjebak. Gang sempit."


def skill_id_for(db, name: str) -> int:
    return db.scalar(select(Skill).where(Skill.name == name)).id


def signup(client, db, phone, name="User", volunteer_skills=None):
    body = {"name": name, "phone": phone, "password": "rahasia1"}
    if volunteer_skills:
        body |= {"become_volunteer": True,
                 "skills": [{"skill_id": skill_id_for(db, s)} for s in volunteer_skills]}
    r = client.post("/auth/register", json=body)
    assert r.status_code == 200, r.text
    r = client.post("/auth/verify-otp", json={"phone": phone, "code": r.json()["dev_otp"]})
    assert r.status_code == 200, r.text
    token = r.json()["token"]
    return {"Authorization": f"Bearer {token}"}, r.json()["user"]["id"]


def add_volunteers(db, n, skill_name="P3K", start_km=0.3, step_km=0.3):
    skill_id = skill_id_for(db, skill_name)
    ids = []
    for i in range(n):
        lat, lng = offset_point(*SITE, start_km + i * step_km, 40 * i)
        u = User(name=f"Relawan {i + 1}", phone=f"0877{i:08d}", password_hash="!", phone_verified=True,
                 lat=lat, lng=lng)
        db.add(u)
        db.flush()
        db.add(VolunteerProfile(user_id=u.id, is_active=True))
        db.add(VolunteerSkill(user_id=u.id, skill_id=skill_id))
        ids.append(u.id)
    db.commit()
    return ids


def create_active_report(client, headers, db, quota=2, skill_name="P3K"):
    r = client.post("/reports", headers=headers, json={"description": TEXT, "lat": SITE[0], "lng": SITE[1]})
    assert r.status_code == 200, r.text
    data = r.json()
    assert data["report"]["status"] == "draft"
    assert data["proposed_needs"] == []  # manual selection until Task 4 wires real AI proposals
    rid = data["report"]["id"]
    r = client.post(f"/reports/{rid}/confirm", headers=headers,
                    json={"needs": [{"skill_id": skill_id_for(db, skill_name), "quota": quota}],
                          "fields": {}})
    assert r.status_code == 200, r.text
    return rid


def offers_of(db, rid):
    db.expire_all()
    return db.scalars(select(Offer).where(Offer.report_id == rid).order_by(Offer.rank)).all()


def test_register_login_and_otp(client):
    r = client.post("/auth/register", json={"name": "Ani", "phone": "+62 812-1111-2222", "password": "rahasia1"})
    assert r.json()["phone"] == "081211112222"
    r = client.post("/auth/login", json={"phone": "081211112222", "password": "rahasia1"})
    assert r.status_code == 403  # not verified yet
    code = r.json()["detail"]["dev_otp"]
    assert client.post("/auth/verify-otp", json={"phone": "081211112222", "code": "000000" if code != "000000"
                                                  else "111111"}).status_code == 400
    r = client.post("/auth/verify-otp", json={"phone": "081211112222", "code": code})
    assert r.status_code == 200
    me = client.get("/me", headers={"Authorization": f"Bearer {r.json()['token']}"}).json()
    assert me["phone_masked"] == "0812****2222"
    assert me["volunteer"] is None
    assert me["trust"]["label"] == "Akun baru"


def test_report_requires_account(client):
    assert client.post("/reports", json={"description": TEXT, "lat": 0, "lng": 0}).status_code == 401


def test_volunteer_toggle_and_reporter_can_still_report(client, db):
    h, uid = signup(client, db, "081200001111", volunteer_skills=["P3K"])
    r = client.patch("/me/volunteer/active", headers=h, json={"is_active": False})
    assert r.json()["volunteer"]["is_active"] is False
    r = client.post("/reports", headers=h, json={"description": TEXT, "lat": SITE[0], "lng": SITE[1]})
    assert r.status_code == 200


def test_full_dispatch_flow(client, db):
    vols = add_volunteers(db, 8)
    rep_h, rep_id = signup(client, db, "081200000009", "Pelapor")
    rid = create_active_report(client, rep_h, db, quota=2)

    offers = offers_of(db, rid)
    assert len(offers) == 8
    batch1 = [o for o in offers if o.batch_number == 1]
    assert [o.rank for o in batch1] == [1, 2]  # Batch 1 = Required Need
    assert all(o.alarm_sent_at for o in batch1)
    kinds = {n.user_id: n.kind for n in db.scalars(select(Notification))}
    assert kinds[batch1[0].volunteer_id] == "alarm"
    assert kinds[offers[5].volunteer_id] == "standard"  # FR-5.7

    # reporter sees contacted count (FR-2.6)
    view = client.get(f"/reports/{rid}", headers=rep_h).json()
    assert view["contacted_total"] == 8 and view["needs"][0]["status"] == "belum_ada"

    # one of batch 1 accepts within the alarm -> utama, first responder
    a1 = dispatch.accept_offer(db, batch1[0])
    db.commit()
    assert (a1.role, a1.order_number) == ("utama", 1)

    # the other rejects -> whole batch no longer pending -> immediate escalation (FR-5.10)
    dispatch.reject_offer(db, batch1[1])
    dispatch.tick(db)
    db.commit()
    offers = offers_of(db, rid)
    batch2 = [o for o in offers if o.batch_number == 2]
    assert len(batch2) == 0  # batch 1 still has an accepted member, so no early escalation

    # after the 30 s alarm, batch 2 = remaining need (1)
    dispatch.tick(db, utcnow() + timedelta(seconds=31))
    db.commit()
    batch2 = [o for o in offers_of(db, rid) if o.batch_number == 2]
    assert len(batch2) == 1

    # next window: batch 3 = remaining * 2
    dispatch.tick(db, utcnow() + timedelta(seconds=62))
    db.commit()
    batch3 = [o for o in offers_of(db, rid) if o.batch_number == 3]
    assert len(batch3) == 2

    # proactive accept from a not-yet-alarmed candidate fills the quota -> utama
    waiting = [o for o in offers_of(db, rid) if o.batch_number is None]
    a2 = dispatch.accept_offer(db, waiting[0])
    db.commit()
    assert a2.role == "utama"
    need = db.scalar(select(Need).where(Need.report_id == rid))
    assert need.status == "penuh"

    # the one who rejected changes their mind -> tambahan (4.11)
    a3 = dispatch.accept_offer(db, db.get(Offer, batch1[1].id))
    db.commit()
    assert a3.role == "tambahan"

    # a batch-2 volunteer accepting after the 5-minute window -> tambahan
    a4 = dispatch.accept_offer(db, db.get(Offer, batch2[0].id), utcnow() + timedelta(minutes=6))
    db.commit()
    assert a4.role == "tambahan"

    # no further alarms once the need is full
    before = len([o for o in offers_of(db, rid) if o.batch_number])
    dispatch.tick(db, utcnow() + timedelta(seconds=200))
    assert len([o for o in offers_of(db, rid) if o.batch_number]) == before

    # ---- collective confirmation -------------------------------------------
    report = db.get(Report, rid)
    participants = db.scalars(select(Participant).where(Participant.report_id == rid)).all()
    assert len(participants) == 5  # reporter + 4 volunteers
    t0 = utcnow()
    confirmation.mark_arrival(db, report, t0)
    confirmation.tick(db, t0)  # first popup round
    db.commit()
    assert client.get("/me/prompts", headers=rep_h).json()["confirm"]

    # two people answer, three ignore a full period -> AFK
    confirmation.vote(db, report, db.get(User, a1.volunteer_id), True, t0 + timedelta(seconds=10))
    confirmation.vote(db, report, db.get(User, a2.volunteer_id), False, t0 + timedelta(seconds=10))
    confirmation.tick(db, t0 + timedelta(seconds=121))
    db.commit()
    state = confirmation.quorum_state(db, report)
    assert state["afk"] == 3 and state["active"] == 2
    assert state["required"] == 2 and state["votes"] == 1
    assert report.status == "active"

    # the reporter comes back and confirms via the API -> quorum over active voters
    r = client.post(f"/reports/{rid}/vote", headers=rep_h, json={"done": True})
    assert r.status_code == 200
    db.expire_all()
    report = db.get(Report, rid)
    assert report.status == "active"  # 2 of 3 active: T(3) = 3
    confirmation.vote(db, report, db.get(User, a2.volunteer_id), True)
    db.commit()
    db.expire_all()
    assert db.get(Report, rid).status == "resolved"

    # ---- experience update (4.12) ------------------------------------------
    p1 = db.get(VolunteerProfile, a1.volunteer_id)
    p3 = db.get(VolunteerProfile, a3.volunteer_id)
    assert p1.completion_count == 1 and p1.disaster_experience == {"kebakaran": 1}
    assert p1.skills[0].verified_experience == 1
    assert p3.completion_count == 0 and p3.disaster_experience == {"kebakaran": 1}
    assert all(a.status == "selesai" for a in db.scalars(select(Assignment).where(Assignment.report_id == rid)))


def test_cross_skill_credit_fills_second_need_without_separate_alarm(client, db):
    rep_h, _ = signup(client, db, "081200000020", "Pelapor Multi")
    p3k_id = skill_id_for(db, "P3K")
    apar_id = skill_id_for(db, "Penggunaan APAR")

    # one volunteer with BOTH skills, close by
    multi_h, multi_id = signup(client, db, "081200000021", "Relawan Serba Bisa",
                               volunteer_skills=["P3K", "Penggunaan APAR"])
    client.post("/me/location", headers=multi_h, json={"lat": SITE[0] + 0.005, "lng": SITE[1]})

    r = client.post("/reports", headers=rep_h, json={"description": TEXT, "lat": SITE[0], "lng": SITE[1]})
    rid = r.json()["report"]["id"]
    r = client.post(f"/reports/{rid}/confirm", headers=rep_h,
                    json={"needs": [{"skill_id": p3k_id, "quota": 1}, {"skill_id": apar_id, "quota": 1}],
                          "fields": {}})
    assert r.status_code == 200, r.text

    offers = offers_of(db, rid)
    p3k_offer = next(o for o in offers if db.get(Need, o.need_id).skill_id == p3k_id)
    assert p3k_offer.volunteer_id == multi_id  # only volunteer in range

    a = dispatch.accept_offer(db, p3k_offer)
    db.commit()

    apar_need = db.scalar(select(Need).where(Need.report_id == rid, Need.skill_id == apar_id))
    assert apar_need.status == "penuh"  # credited without a separate offer/alarm
    assert dispatch.accepted_count(db, apar_need.id) == 1
    db.expire_all()
    assert sorted(db.get(Assignment, a.id).credited_skill_ids) == [apar_id]

    # ---- experience update on resolution (4.12) credits BOTH skills --------
    report = db.get(Report, rid)
    confirmation.resolve(db, report, "quorum")
    db.commit()
    db.expire_all()
    profile = db.get(VolunteerProfile, multi_id)
    by_skill = {s.skill_id: s.verified_experience for s in profile.skills}
    assert by_skill[p3k_id] == 1
    assert by_skill[apar_id] == 1


def test_release_assignment_reverts_credited_need_status(client, db):
    """A need only filled via cross-skill credit must not stay stuck 'penuh'
    forever once its sole coverage is released -- otherwise dispatch.tick can
    never see or re-alarm it again (it only scans belum_ada/sebagian needs)."""
    rep_h, _ = signup(client, db, "081200000022", "Pelapor Multi 2")
    p3k_id = skill_id_for(db, "P3K")
    apar_id = skill_id_for(db, "Penggunaan APAR")

    multi_h, multi_id = signup(client, db, "081200000023", "Relawan Serba Bisa 2",
                               volunteer_skills=["P3K", "Penggunaan APAR"])
    client.post("/me/location", headers=multi_h, json={"lat": SITE[0] + 0.005, "lng": SITE[1]})

    r = client.post("/reports", headers=rep_h, json={"description": TEXT, "lat": SITE[0], "lng": SITE[1]})
    rid = r.json()["report"]["id"]
    r = client.post(f"/reports/{rid}/confirm", headers=rep_h,
                    json={"needs": [{"skill_id": p3k_id, "quota": 1}, {"skill_id": apar_id, "quota": 1}],
                          "fields": {}})
    assert r.status_code == 200, r.text

    offers = offers_of(db, rid)
    p3k_offer = next(o for o in offers if db.get(Need, o.need_id).skill_id == p3k_id)
    a = dispatch.accept_offer(db, p3k_offer)
    db.commit()

    apar_need = db.scalar(select(Need).where(Need.report_id == rid, Need.skill_id == apar_id))
    assert apar_need.status == "penuh"

    dispatch.release_assignment(db, a)
    db.commit()
    db.expire_all()
    apar_need = db.scalar(select(Need).where(Need.report_id == rid, Need.skill_id == apar_id))
    assert apar_need.status == "belum_ada"


def test_no_candidates_is_visible_not_silent(client, db):
    rep_h, _ = signup(client, db, "081200000010")
    rid = create_active_report(client, rep_h, db, quota=3)
    view = client.get(f"/reports/{rid}", headers=rep_h).json()
    assert view["status"] == "active"
    assert view["needs"][0]["status"] == "belum_ada" and view["needs"][0]["exhausted"] is True


def test_confirm_blocked_when_content_flagged_invalid(client, db):
    """Guardrail: a report the AI judged as gibberish/spam cannot be confirmed
    into an active incident until the reporter rewrites it."""
    p3k_id = skill_id_for(db, "P3K")
    rep_h, _ = signup(client, db, "081200000017")
    r = client.post("/reports", headers=rep_h, json={"description": TEXT, "lat": SITE[0], "lng": SITE[1]})
    rid = r.json()["report"]["id"]

    report = db.get(Report, rid)
    report.content_valid = False
    db.commit()

    r = client.post(f"/reports/{rid}/confirm", headers=rep_h,
                    json={"needs": [{"skill_id": p3k_id, "quota": 1}], "fields": {}})
    assert r.status_code == 422, r.text
    db.expire_all()
    assert db.get(Report, rid).status == "draft"  # never activated


def test_reporter_never_matched_to_own_report(client, db):
    add_volunteers(db, 2)
    h, uid = signup(client, db, "081200000011", volunteer_skills=["P3K"])
    client.post("/me/location", headers=h, json={"lat": SITE[0], "lng": SITE[1]})
    rid = create_active_report(client, h, db)
    assert uid not in {o.volunteer_id for o in offers_of(db, rid)}


def test_volunteer_api_accept_and_task(client, db):
    rep_h, _ = signup(client, db, "081200000012")
    vol_h, vol_id = signup(client, db, "081200000013", "Relawan Asli", volunteer_skills=["P3K"])
    client.post("/me/location", headers=vol_h, json={"lat": SITE[0] + 0.005, "lng": SITE[1]})
    rid = create_active_report(client, rep_h, db, quota=1)

    reqs = client.get("/volunteer/requests", headers=vol_h).json()
    assert len(reqs) == 1 and reqs[0]["alarm_active"] is True
    assert reqs[0]["reporter_trust"]["label"] == "Akun baru"  # FR-9.3
    assert "08" in reqs[0]["contact_phone_masked"] and "*" in reqs[0]["contact_phone_masked"]

    task = client.post(f"/offers/{reqs[0]['offer_id']}/accept", headers=vol_h).json()
    assert task["role"] == "utama" and task["order_number"] == 1
    task = client.post(f"/assignments/{task['id']}/travel-status", headers=vol_h, json={"status": "sampai"}).json()
    assert task["travel_status"] == "sampai"

    view = client.get(f"/reports/{rid}", headers=rep_h).json()
    assert view["volunteers"][0]["name"] == "Relawan Asli"
    assert view["needs"][0]["status"] == "penuh"

    # reporter + volunteer both confirm -> resolved (T(2) = 2)
    client.post(f"/reports/{rid}/vote", headers=vol_h, json={"done": True})
    view = client.post(f"/reports/{rid}/vote", headers=rep_h, json={"done": True}).json()
    assert view["status"] == "resolved"

    prompts = client.get("/me/prompts", headers=vol_h).json()
    assert prompts["accuracy"][0]["report_id"] == rid
    assert client.post(f"/reports/{rid}/accuracy", headers=vol_h, json={"matches": True}).status_code == 200


def test_volunteer_cannot_accept_second_active_task(client, db):
    """A volunteer already on an active task must be refused a second one,
    even on a different report (relawan hanya boleh 1 tugas aktif)."""
    rep1_h, _ = signup(client, db, "081200000016")
    rep2_h, _ = signup(client, db, "081200000017")
    vol_h, vol_id = signup(client, db, "081200000018", "Relawan Sibuk", volunteer_skills=["P3K"])
    client.post("/me/location", headers=vol_h, json={"lat": SITE[0] + 0.005, "lng": SITE[1]})

    rid1 = create_active_report(client, rep1_h, db, quota=1)
    offer1 = client.get("/volunteer/requests", headers=vol_h).json()[0]
    task = client.post(f"/offers/{offer1['offer_id']}/accept", headers=vol_h).json()
    assert task["status"] == "aktif"

    rid2 = create_active_report(client, rep2_h, db, quota=1)
    reqs = client.get("/volunteer/requests", headers=vol_h).json()
    assert [r["report_id"] for r in reqs] == [rid2]  # rid1's offer is already accepted, not listed here

    r = client.post(f"/offers/{reqs[0]['offer_id']}/accept", headers=vol_h)
    assert r.status_code == 409
    assert "tugas aktif lain" in r.json()["detail"]

    db.expire_all()
    active = db.scalars(select(Assignment).where(Assignment.volunteer_id == vol_id,
                                                  Assignment.status == "aktif")).all()
    assert len(active) == 1 and active[0].report_id == rid1

    view = client.get(f"/reports/{rid2}", headers=rep2_h).json()
    assert view["needs"][0]["status"] == "belum_ada"  # still unfulfilled, no volunteer took it


def test_sighting_and_nearby_widget(client, db):
    rep_h, _ = signup(client, db, "081200000014")
    other_h, _ = signup(client, db, "081200000015")
    client.post("/me/location", headers=other_h, json={"lat": SITE[0] + 0.01, "lng": SITE[1]})
    rid = create_active_report(client, rep_h, db)
    nearby = client.get("/reports/nearby", headers=other_h).json()
    assert [r["id"] for r in nearby["notified"]] == [rid]
    view = client.post(f"/reports/{rid}/sightings", headers=other_h).json()
    assert view["sightings"] == 1 and view["i_saw"] is True
    assert "volunteers" not in view  # uninvolved users get the limited view (NFR-15)


def test_trust_tier_from_accuracy(db):
    from app.db.models import AccuracyFeedback
    from app.services.trust import trust_tier
    u = User(name="R", phone="081299999999", password_hash="!")
    db.add(u)
    db.flush()
    for i, ok in enumerate([True, True, False]):
        db.add(AccuracyFeedback(report_id=f"r{i}", reporter_id=u.id, user_id=f"v{i}", matches=ok))
    db.commit()
    assert trust_tier(db, u.id) == "rendah"  # 2/3 < 0.7
    db.add(AccuracyFeedback(report_id="r3", reporter_id=u.id, user_id="v", matches=True))
    db.commit()
    assert trust_tier(db, u.id) == "baik"  # 3/4


def test_config_is_tunable(client, db):
    h, _ = signup(client, db, "081200000016")
    assert client.put("/config/alarm_seconds", headers=h, json={"value": 60}).json() == {"alarm_seconds": 60}
    assert client.get("/config").json()["alarm_seconds"] == 60


def test_unknown_incident_type_is_labelled_by_its_title_not_as_fire(client, db):
    h, _ = signup(client, db, "081200000031")
    r = client.post("/reports", headers=h, json={
        "description": "", "input_mode": "form", "lat": SITE[0], "lng": SITE[1],
        "structured": {"title": "penculikan", "description": "Jenis kejadian: penculikan. Anak dibawa orang asing."},
    })
    assert r.status_code == 200, r.text
    report = r.json()["report"]
    assert report["incident_type"] == "lainnya"
    assert report["incident_label"] == "Penculikan"
    # Agencies for an unknown incident: no fire brigade first.
    agencies = client.get("/agencies/suggest", headers=h, params={"report_id": report["id"]}).json()
    assert "Damkar" not in agencies["primary"]["name"]

    # The reporter's corrected title is what the label follows.
    p3k = skill_id_for(db, "P3K")
    r = client.post(f"/reports/{report['id']}/confirm", headers=h,
                    json={"fields": {"title": "Penculikan anak"}, "needs": [{"skill_id": p3k, "quota": 1}]})
    assert r.json()["incident_label"] == "Penculikan anak"


def test_reporter_picks_and_corrects_incident_type(client, db):
    h, _ = signup(client, db, "081200000032")
    types = client.get("/incident-types").json()
    assert [t["code"] for t in types][-1] == "lainnya"

    # The form sends its choice directly -- no keyword guessing.
    r = client.post("/reports", headers=h, json={
        "description": "", "input_mode": "form", "lat": SITE[0], "lng": SITE[1],
        "structured": {"title": "Jalan ke desa tertutup", "description": "Warga tidak bisa keluar.",
                       "incident_type": "akses_terputus"},
    })
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["report"]["incident_label"] == "Akses terputus / terisolasi"
    assert body["incident_types"] == types

    # Unknown codes are rejected, on submit and on confirm.
    bad = client.post("/reports", headers=h, json={
        "description": "", "input_mode": "form", "lat": SITE[0], "lng": SITE[1],
        "structured": {"title": "x", "incident_type": "gempa"},
    })
    assert bad.status_code == 422
    rid = body["report"]["id"]
    p3k = skill_id_for(db, "P3K")
    bad = client.post(f"/reports/{rid}/confirm", headers=h,
                      json={"needs": [{"skill_id": p3k, "quota": 1}], "incident_type": "gempa"})
    assert bad.status_code == 422

    r = client.post(f"/reports/{rid}/confirm", headers=h,
                    json={"needs": [{"skill_id": p3k, "quota": 1}], "incident_type": "longsor"})
    assert r.status_code == 200, r.text
    assert r.json()["incident_label"] == "Tanah longsor"

    # The app picks map/list icons from incident_type, so every list must carry it.
    assert [m["incident_type"] for m in client.get("/reports/active", headers=h).json()] == ["longsor"]
    assert [m["incident_type"] for m in client.get("/reports/mine", headers=h).json()] == ["longsor"]
    other, _ = signup(client, db, "081200000033")
    nearby = client.get("/reports/nearby", headers=other).json()
    assert {m["incident_type"] for m in nearby["notified"] + nearby["general"]} <= {"longsor"}


def test_seed_syncs_agency_incident_types(db):
    from app.db.models import Agency
    from app.services.agencies import seed_agencies
    basarnas = db.scalar(select(Agency).where(Agency.name == "Basarnas"))
    basarnas.incident_types = ["kebakaran", "banjir", "longsor", "gempa"]  # a pre-change database
    db.commit()
    seed_agencies(db)
    db.refresh(basarnas)
    assert "bangunan_roboh" in basarnas.incident_types and "gempa" not in basarnas.incident_types


def test_app_payloads_for_skill_catalog(client, db):
    """The request shapes the Flutter app sends: public skill catalog for
    sign-up, volunteer skills by id, a structured-form report, and needs
    confirmed by skill_id."""
    catalog = client.get("/skills").json()  # no token: sign-up happens before login
    assert {"skill_id", "name"} <= catalog[0].keys()
    apar = next(c["skill_id"] for c in catalog if c["name"] == "Penggunaan APAR")

    h, _ = signup(client, db, "081200000030")
    r = client.post("/me/volunteer", headers=h, json={"skills": [{"skill_id": apar, "evidence": "certified"}]})
    assert r.status_code == 200, r.text
    assert r.json()["volunteer"]["skills"][0]["skill"] == "Penggunaan APAR"

    r = client.post("/reports", headers=h, json={
        "description": "", "input_mode": "form", "lat": SITE[0], "lng": SITE[1],
        "structured": {"title": "Banjir di Gang Mawar",
                       "description": "Jenis kejadian: Banjir. Kondisi akses: sempit tapi bisa dilewati."},
    })
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["report"]["incident_type"] == "banjir"
    assert body["proposed_needs"] == []
    assert body["catalog"] == catalog

    rid = body["report"]["id"]
    r = client.post(f"/reports/{rid}/confirm", headers=h,
                    json={"fields": {"title": "Banjir di Gang Mawar"}, "needs": [{"skill_id": apar, "quota": 2}]})
    assert r.status_code == 200, r.text
    assert r.json()["needs"][0]["skill_name"] == "Penggunaan APAR"
