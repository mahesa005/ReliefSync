"""Report photo storage: Supabase Storage when configured, else local ./uploads."""
import uuid

import httpx

from ..config import get_settings

ALLOWED = {"image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/heic": "heic"}


def save_photo(data: bytes, content_type: str) -> str:
    """Returns a public URL (Supabase) or an API-relative path (/uploads/...)."""
    s = get_settings()
    ext = ALLOWED.get(content_type, "jpg")
    name = f"{uuid.uuid4()}.{ext}"
    if s.supabase_url and s.supabase_service_role_key:
        url = f"{s.supabase_url.rstrip('/')}/storage/v1/object/{s.supabase_bucket}/{name}"
        r = httpx.post(url, content=data, timeout=20, headers={
            "Authorization": f"Bearer {s.supabase_service_role_key}",
            "Content-Type": content_type,
        })
        r.raise_for_status()
        return f"{s.supabase_url.rstrip('/')}/storage/v1/object/public/{s.supabase_bucket}/{name}"
    s.upload_dir.mkdir(parents=True, exist_ok=True)
    (s.upload_dir / name).write_bytes(data)
    return f"/uploads/{name}"
