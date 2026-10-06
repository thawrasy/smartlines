"""What an API client may do: scopes, which client kinds may hold them, and the events it may subscribe to."""

# scope -> what it allows
SCOPES = {
    "trips:read": "Search published trips and read fares and seat availability",
    "bookings:read": "Read the company's bookings and tickets",
    "bookings:write": "Hold seats, sell and cancel tickets (sales channels)",
    "manifests:read": "Read the passenger manifest of the company's trips",
    "shipments:read": "Track parcels and shipments",
    "reports:read": "Run catalog reports and export them (JSON, CSV, TXT, XLSX, PDF)",
    "wallet:credit": "Credit passenger wallets with money collected by the partner (banks and e-wallets)",
    "border:read": "Read submitted border manifests (authorities)",
    "border:respond": "Send decisions on border manifests (authorities)",
    "manifests:receive": "Receive and acknowledge the trip manifests routed to the authority, domestic and international",
    "webhooks:manage": "Subscribe to events and manage webhook endpoints",
}

# client kind -> scopes it may be granted
KIND_SCOPES = {
    "CARRIER": {"trips:read", "bookings:read", "manifests:read", "shipments:read", "reports:read", "webhooks:manage"},
    "CHANNEL": {"trips:read", "bookings:read", "bookings:write", "shipments:read", "reports:read", "webhooks:manage"},
    "PARTNER": {"trips:read", "wallet:credit", "webhooks:manage"},
    "AUTHORITY": {"trips:read", "border:read", "border:respond", "manifests:receive", "reports:read", "webhooks:manage"},
    "INTEGRATION": {"bookings:read", "reports:read", "webhooks:manage"},
    "INTERNAL": set(SCOPES),
}

# company type a kind belongs to (None: a client of the platform itself)
KIND_COMPANY = {
    "CARRIER": {"CARRIER", "INDIVIDUAL_OPERATOR", "FOREIGN_CARRIER"},
    "CHANNEL": {"AGENCY"},
    "INTEGRATION": {"CARRIER", "INDIVIDUAL_OPERATOR", "FOREIGN_CARRIER", "AGENCY", None},
    "PARTNER": {None},
    "AUTHORITY": {None},
    "INTERNAL": {None},
}

# scopes that act through a staff account: the account must still hold one of these permissions
SCOPE_PERMISSIONS = {
    "bookings:read": ("booking.on_behalf", "report.company", "manifest.view", "report.platform"),
    "bookings:write": ("booking.on_behalf",),
    "manifests:read": ("manifest.view", "trip.publish"),
    "reports:read": ("report.company", "report.platform"),
}

# event -> client kinds that may receive it; the rows themselves are filtered by company (see webhooks.receives)
EVENTS = {
    "booking.confirmed": {"CARRIER", "CHANNEL", "INTEGRATION", "INTERNAL"},
    "booking.cancelled": {"CARRIER", "CHANNEL", "INTEGRATION", "INTERNAL"},
    "shipment.created": {"CARRIER", "INTEGRATION", "INTERNAL"},
    "subscription.activated": {"CARRIER", "INTEGRATION", "INTERNAL"},
    "rental.requested": {"CARRIER", "INTEGRATION", "INTERNAL"},
    "freight.bid_accepted": {"CARRIER", "INTEGRATION", "INTERNAL"},
    "withdrawal.paid": {"CARRIER", "CHANNEL", "INTEGRATION", "INTERNAL"},
    "withdrawal.rejected": {"CARRIER", "CHANNEL", "INTEGRATION", "INTERNAL"},
    "document.approved": {"CARRIER", "CHANNEL", "INTERNAL"},
    "document.rejected": {"CARRIER", "CHANNEL", "INTERNAL"},
    "wallet.credited": {"PARTNER", "INTERNAL"},
    "border.manifest_submitted": {"AUTHORITY", "INTERNAL"},
    "manifest.issued": {"CARRIER", "INTEGRATION", "INTERNAL"},
    "manifest.available": {"AUTHORITY", "INTERNAL"},
    "webhook.ping": set(KIND_SCOPES),
}

# personal fields removed from webhook payloads unless the endpoint was approved for personal data
PERSONAL_FIELDS = {"contact_mobile", "booker_user_id", "mobile", "email", "full_name", "passenger_name"}
