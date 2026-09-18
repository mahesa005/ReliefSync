"""Notifications. Every notification is stored in the in-app inbox (the app polls
it, so the demo works without Firebase). If FIREBASE_CREDENTIALS is set and
``firebase-admin`` is installed, it is also pushed through FCM:

  * kind "alarm"    -> Android: data-only, high priority. The app renders it
                       itself (channel ``relief_alarm``) as a full-screen,
                       insistent notification that rings until answered --
                       a system-rendered ``notification`` payload can't do that.
  * everything else -> ``notification`` payload on channel ``relief_standard``,
                       rendered by the system with the default sound.     (NFR-7)

Payloads never carry the reporter's unmasked phone number (NFR-14).
"""
import json
import logging
from datetime import timedelta
from functools import lru_cache

from sqlalchemy.orm import Session

from ..core.config import get_settings
from ..db.models import Notification, User

log = logging.getLogger("reliefsync.notify")


@lru_cache
def _firebase():
    raw = get_settings().firebase_credentials.strip()
    if not raw:
        return None
    try:
        import firebase_admin
        from firebase_admin import credentials, messaging

        # Either a path to the service-account JSON, or the JSON itself -- the
        # latter is what hosts like Railway make easy (paste it into an env var).
        source = json.loads(raw) if raw.startswith("{") else raw
        firebase_admin.initialize_app(credentials.Certificate(source))
        return messaging
    except Exception as exc:  # noqa: BLE001
        log.warning("FCM disabled: %s", exc)
        return None


def _push(user: User, n: Notification) -> None:
    messaging = _firebase()
    if messaging is None or not user.fcm_token:
        return
    alarm = n.kind == "alarm"
    data = {k: str(v) for k, v in {**n.data, "kind": n.kind, "notification_id": n.id,
                                    "title": n.title, "body": n.body}.items()}
    aps = messaging.Aps(
        alert=messaging.ApsAlert(title=n.title, body=n.body),
        sound="alarm.caf" if alarm else "default",
        category="RELIEF_ALARM" if alarm else "RELIEF_STANDARD",
    )
    if alarm:
        # No `notification` block: Android must hand this to the app's background
        # handler instead of rendering it itself. A stale alarm is useless once
        # the batch window has passed, so don't deliver it late.
        android = messaging.AndroidConfig(priority="high", ttl=timedelta(minutes=2))
        notification = None
    else:
        android = messaging.AndroidConfig(
            priority="high",
            notification=messaging.AndroidNotification(channel_id="relief_standard", sound="default"),
        )
        notification = messaging.Notification(title=n.title, body=n.body)
    try:
        messaging.send(messaging.Message(
            token=user.fcm_token,
            notification=notification,
            data=data,
            android=android,
            apns=messaging.APNSConfig(headers={"apns-priority": "10"}, payload=messaging.APNSPayload(aps=aps)),
        ))
    except Exception as exc:  # noqa: BLE001 -- a failed push must never break the flow
        log.warning("FCM send failed for %s: %s", user.id, exc)


def notify(db: Session, user: User, kind: str, title: str, body: str = "", data: dict | None = None) -> Notification:
    """Queue a notification. Does NOT flush -- dispatch fans this out to every
    matched/nearby candidate in a single request, and a flush per call means one
    round trip per candidate to the DB (very slow against a remote Supabase
    pooler: seconds per notification, timing out the client). The caller flushes
    once after the batch (or the request's final ``db.commit()`` does it)."""
    n = Notification(user_id=user.id, kind=kind, title=title, body=body, data=data or {})
    db.add(n)
    if not user.is_simulated:
        log.info("notify[%s] %s -> %s", kind, user.name, title)
        messaging = _firebase()
        if messaging is not None and user.fcm_token:
            db.flush()  # only needed here: the FCM payload embeds n.id
            _push(user, n)
    return n
