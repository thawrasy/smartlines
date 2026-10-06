"""Passenger categories and family offers (4.19), families as the platform sees them (4.20), and manifest routing (11.10)."""
from ._base import Action, P, O, Resource, activate, c, retire, suspend, resume

M_CAT, M_FAM, M_MAN = "passenger_categories", "family_accounts", "trip_manifests"
FARES = {P: "fares.categories", O: "fares.categories"}

RESOURCES = [
    Resource("age-band", M_CAT, "pricing.passenger_age_band",
             c("company_id category min_age max_age seat_required needs_adult max_per_adult status"),
             c("company_id category min_age max_age seat_required needs_adult max_per_adult"), FARES, company_col="company_id",
             creator_col="created_by", group="categories", order="company_id NULLS FIRST, min_age",
             defaults={"status": "DRAFT"}, actions=(activate(("DRAFT",)), retire())),
    Resource("category-fare", M_CAT, "pricing.category_fare_rule",
             c("company_id category route_id method value currency valid status"),
             c("company_id category route_id method value currency valid"), FARES, company_col="company_id",
             creator_col="created_by", group="categories", defaults={"status": "DRAFT"},
             actions=(activate(("DRAFT",)), retire())),
    Resource("family-offer", M_CAT, "pricing.family_offer",
             c("code name company_id applies_to min_members min_adults min_minors discount_type discount_value max_discount route_id valid status"),
             c("code name company_id applies_to min_members min_adults min_minors discount_type discount_value max_discount route_id valid"),
             {P: "fares.categories", O: "fares.categories"}, company_col="company_id", creator_col="created_by", group="offers",
             actions=(activate(("DRAFT", "SUSPENDED")), suspend(), retire(("ACTIVE", "SUSPENDED")))),

    # Families stay private: the platform sees the register for support and audit, not the identity details
    Resource("family", M_FAM, "iam.family", c("uid name head_party_id status created_at"), (), {P: "privacy.manage"},
             create=False, update=False, group="families", order="created_at DESC",
             actions=(Action("close", {"status": "CLOSED"}, {"status": ["ACTIVE"]}),)),
    Resource("family-link-request", M_FAM, "iam.family_link_request",
             c("uid family_id member_id status device_label submitted_at decided_at expires_at"), (), {P: "privacy.manage"},
             create=False, update=False, group="families", order="created_at DESC"),

    Resource("manifest-route", M_MAN, "brd.manifest_route",
             c("authority_id scope content_type manifest_types country_code border_point_id city_id company_id channel format "
               "include_documents legal_basis status approved_at"),
             c("authority_id scope content_type manifest_types country_code border_point_id city_id company_id channel format "
               "include_documents legal_basis"), {P: "manifest.routes"}, creator_col="created_by", group="routing",
             actions=(Action("approve", {"status": "ACTIVE"}, {"status": ["DRAFT"]}, four_eyes=("created_by", "approved_by"),
                             stamp="approved_at"),
                      suspend(), resume(), retire(("ACTIVE", "SUSPENDED", "DRAFT")))),
    Resource("trip-manifest", M_MAN, "brd.manifest",
             c("uid trip_id scope border_point_id manifest_type version status persons_count issued_at"), (),
             {P: "manifest.routes", O: "manifest.issue"}, create=False, update=False, group="manifests", order="id DESC"),
    Resource("manifest-delivery", M_MAN, "brd.manifest_delivery",
             c("uid manifest_id authority_id channel status attempts ack_ref sent_at acknowledged_at last_error"), (),
             {P: "manifest.routes", O: "manifest.issue"}, create=False, update=False, group="manifests", order="id DESC",
             actions=(Action("retry", {"status": "PENDING", "attempts": 0}, {"status": ["FAILED"]}, portals=(P,)),)),
]
