import math

EARTH_RADIUS_KM = 6371.0088

# Rough bounding box of DKI Jakarta, used to pick region-specific agencies (FR-10.1).
JAKARTA_BBOX = (-6.38, 106.68, -6.08, 106.98)  # (min_lat, min_lng, max_lat, max_lng)


def haversine_km(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = p2 - p1
    dl = math.radians(lng2 - lng1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * EARTH_RADIUS_KM * math.asin(math.sqrt(a))


def region_of(lat: float, lng: float) -> str:
    min_lat, min_lng, max_lat, max_lng = JAKARTA_BBOX
    if min_lat <= lat <= max_lat and min_lng <= lng <= max_lng:
        return "jakarta"
    return "nasional"


def move_towards(lat: float, lng: float, target_lat: float, target_lng: float,
                 meters: float) -> tuple[float, float, bool]:
    """Move a point `meters` towards a target. Returns (lat, lng, arrived)."""
    remaining_km = haversine_km(lat, lng, target_lat, target_lng)
    step_km = meters / 1000
    if remaining_km <= step_km or remaining_km == 0:
        return target_lat, target_lng, True
    f = step_km / remaining_km
    return lat + (target_lat - lat) * f, lng + (target_lng - lng) * f, False


def offset_point(lat: float, lng: float, distance_km: float, bearing_deg: float) -> tuple[float, float]:
    b = math.radians(bearing_deg)
    dlat = (distance_km / 111.32) * math.cos(b)
    dlng = (distance_km / (111.32 * math.cos(math.radians(lat)))) * math.sin(b)
    return lat + dlat, lng + dlng
