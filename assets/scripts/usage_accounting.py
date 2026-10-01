"""Shared, versioned Claude transcript accounting. No transcript text is retained."""
from decimal import Decimal
from datetime import datetime

RATE_CARD_VERSION = "anthropic-standard-global-2026-09-30"
# USD per million: uncached input, output, 5m write, 1h write, cache read.
RATES = {
    "claude-opus-5-5": (4, 20, 5, 8, ".20"),
    "claude-sonnet-5": (2, 10, "2.50", 4, ".20"),
    "claude-sonnet-5-5": (2, 10, "2.50", 4, ".20"),
    "claude-haiku-4-5-20251001": (1, 5, "1.25", 2, ".10"),
    "claude-haiku-4-5": (1, 5, "1.25", 2, ".10"),
    "claude-opus-5": (5, 25, "6.25", 10, ".50"),
    "claude-fable-5-1": (10, 50, "12.50", 20, ".25"),
    "claude-fable-5": (10, 50, "12.50", 20, 1),
    "claude-mythos-1": (10, 50, "12.50", 20, 1),
    "claude-sonnet-4-5": (3, 15, "3.75", 6, ".30"),
    "claude-sonnet-4-6": (3, 15, "3.75", 6, ".30"),
    "claude-opus-4-5": (5, 25, "6.25", 10, ".50"),
    "claude-opus-4-6": (5, 25, "6.25", 10, ".50"),
    "claude-opus-4-7": (5, 25, "6.25", 10, ".50"),
    "claude-opus-4-8": (5, 25, "6.25", 10, ".50"),
    "claude-opus-4-1": (15, 75, "18.75", 30, "1.50"),
    "claude-haiku-3-5": (".80", 4, 1, "1.60", ".08"),
}
RATES = {model: tuple(Decimal(str(v)) for v in values) for model, values in RATES.items()}
US_PREMIUM_MODELS = {
    "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5", "claude-sonnet-5-5",
    "claude-fable-5", "claude-fable-5-1", "claude-sonnet-4-6",
    "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8",
}
FIELDS = ("input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")


def token_split(usage):
    """Return disjoint token classes and expose unknown cache duration."""
    u = usage or {}
    c = u.get("cache_creation") or {}
    vals = [int(u.get(k) or 0) for k in FIELDS]
    if any(v < 0 for v in vals):
        raise ValueError("negative usage counter")
    c5 = int(c.get("ephemeral_5m_input_tokens") or 0)
    c1 = int(c.get("ephemeral_1h_input_tokens") or 0)
    if c5 < 0 or c1 < 0 or c5 + c1 > vals[2]:
        raise ValueError("inconsistent cache creation split")
    return dict(input_tokens=vals[0], output_tokens=vals[1],
                cache_5m_tokens=c5, cache_1h_tokens=c1,
                cache_read_input_tokens=vals[3],
                cache_ttl_unknown_tokens=vals[2] - c5 - c1)


def price_usage(usage, model):
    """Return Decimal lower/upper USD; unknown TTL is bracketed at 5m/1h rates."""
    if model not in RATES:
        raise ValueError("unpriced model: %s" % model)
    t = token_split(usage)
    ri, ro, r5, r1, rr = RATES[model]
    known = (t["input_tokens"] * ri + t["output_tokens"] * ro +
             t["cache_5m_tokens"] * r5 + t["cache_1h_tokens"] * r1 +
             t["cache_read_input_tokens"] * rr)
    unknown = t["cache_ttl_unknown_tokens"]
    speed = (usage or {}).get("speed")
    service_tier = (usage or {}).get("service_tier")
    geography = (usage or {}).get("inference_geo")
    if speed not in (None, "standard", "fast"):
        raise ValueError("unsupported speed: %s" % speed)
    if service_tier not in (None, "standard", "batch"):
        raise ValueError("unsupported service tier: %s" % service_tier)
    if geography not in (None, "global", "us"):
        raise ValueError("unsupported inference geography: %s" % geography)
    modifier = Decimal(1)
    if speed == "fast":
        if model not in ("claude-opus-5-5", "claude-opus-5", "claude-opus-4-8"):
            raise ValueError("unsupported fast pricing: %s" % model)
        modifier *= 2
    if service_tier == "batch":
        if speed == "fast":
            raise ValueError("fast and batch are incompatible")
        modifier *= Decimal(".5")
    if geography == "us":
        if model not in US_PREMIUM_MODELS:
            raise ValueError("unverified US-inference pricing: %s" % model)
        modifier *= Decimal("1.1")
    scale = Decimal(1000000)
    return {"lower_usd": modifier * (known + unknown * r5) / scale,
            "upper_usd": modifier * (known + unknown * r1) / scale,
            "tokens": t, "rate_card": RATE_CARD_VERSION,
            "speed": speed or "unknown", "service_tier": service_tier or "unknown",
            "inference_geo": geography or "unknown"}


def response_key(record, source, line):
    msg = record.get("message") or {}
    request_id, message_id = record.get("requestId"), msg.get("id")
    if request_id and message_id:
        return ("pair", request_id, message_id)
    if message_id:
        return ("message", message_id)
    if request_id:
        return ("request", request_id)
    return ("unidentified", source, line)


def _clock(record):
    value = record.get("timestamp")
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (TypeError, ValueError, AttributeError):
        return float("-inf")


def _counters(record):
    u = (record.get("message") or {}).get("usage") or {}
    return tuple(int(u.get(field) or 0) for field in FIELDS)


def prefer_response(previous, candidate):
    """Select a coherent cumulative observation without using model price."""
    a, b = _counters(previous["record"]), _counters(candidate["record"])
    if all(x >= y for x, y in zip(b, a)) and any(x > y for x, y in zip(b, a)):
        return candidate
    if all(x >= y for x, y in zip(a, b)) and any(x > y for x, y in zip(a, b)):
        return previous
    if a != b:
        # Incomparable counters are anomalous; keep the completed observation,
        # then the latest. Callers surface the conflict count.
        ac = bool((previous["record"].get("message") or {}).get("stop_reason"))
        bc = bool((candidate["record"].get("message") or {}).get("stop_reason"))
        if ac != bc:
            return candidate if bc else previous
    ac = bool((previous["record"].get("message") or {}).get("stop_reason"))
    bc = bool((candidate["record"].get("message") or {}).get("stop_reason"))
    if ac != bc:
        return candidate if bc else previous
    if previous["role"] != candidate["role"]:
        # Identical observations copied between parent and child have no reliable
        # file-write order. Attribute them to the main transcript consistently;
        # surface the cross-role ambiguity to the caller.
        return previous if previous["role"] == "main" else candidate
    return candidate if (candidate["time"], candidate["source"], candidate["line"]) >= (previous["time"], previous["source"], previous["line"]) else previous


class Responses:
    """One globally deduplicated selection over main, child and copied records."""
    def __init__(self):
        self._groups = {}
        self._resolved = None
        self.conflicts = 0
        self._base_conflicts = 0
        self.unidentified = 0
        self.synthetic = 0
        self.cross_role_pairs = 0
        self._base_cross_role_pairs = 0
        self.ambiguous_identities = 0
        self.by_message = {}
        self.by_request = {}

    def _choose(self, prior, candidate, base=False):
        if prior["role"] != candidate["role"]:
            self.cross_role_pairs += 1
            if base:
                self._base_cross_role_pairs += 1
        a, b = _counters(prior["record"]), _counters(candidate["record"])
        if a != b and not (all(x >= y for x, y in zip(a, b)) or
                           all(x >= y for x, y in zip(b, a))):
            self.conflicts += 1
            if base:
                self._base_conflicts += 1
        return prefer_response(prior, candidate)

    def add(self, record, source, line, role="main"):
        if record.get("type") != "assistant":
            return
        msg = record.get("message") or {}
        if msg.get("model") == "<synthetic>" or record.get("isApiErrorMessage"):
            self.synthetic += 1
            return
        if not isinstance(msg.get("usage"), dict):
            return
        key = response_key(record, source, line)
        if key[0] == "unidentified":
            self.unidentified += 1
        candidate = {"record": record, "source": source, "line": line,
                     "role": role, "time": _clock(record)}
        if key[0] == "pair":
            self.by_request.setdefault(key[1], set()).add(key)
            self.by_message.setdefault(key[2], set()).add(key)
        prior = self._groups.get(key)
        if prior is not None:
            candidate = self._choose(prior, candidate, base=True)
        self._groups[key] = candidate
        self._resolved = None

    @property
    def selected(self):
        if self._resolved is None:
            self.conflicts = self._base_conflicts
            self.cross_role_pairs = self._base_cross_role_pairs
            self.ambiguous_identities = 0
            resolved = {key: item for key, item in self._groups.items()
                        if key[0] not in ("request", "message")}
            for key, item in self._groups.items():
                if key[0] not in ("request", "message"):
                    continue
                pairs = (self.by_request if key[0] == "request" else self.by_message).get(key[1], set())
                if len(pairs) == 1:
                    pair = next(iter(pairs))
                    resolved[pair] = self._choose(resolved[pair], item)
                elif len(pairs) > 1:
                    # No defensible parent, price or timestamp attribution exists.
                    # Exclude the orphan alias and surface the uncertainty.
                    self.ambiguous_identities += 1
                else:
                    resolved[key] = item
            self._resolved = resolved
        return self._resolved

    def rows(self):
        return self.selected.values()

    def without_terminal_metadata(self):
        return sum(not bool((item["record"].get("message") or {}).get("stop_reason"))
                   for item in self.selected.values())
