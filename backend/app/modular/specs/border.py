"""International trips and the border manifest gateway (study 11, 11.9, phases 4 and 6)."""
from ._base import Action, P, O, Resource, c, retire

M_INT, M_BRD = "international", "border_manifest"

RESOURCES = [
    # ------------------------------------------------------------- travel document rules (11.9)
    Resource("entry-rule", M_INT, "sales.entry_rule",
             c("country_code country_role nationality doc_required security_approval passport_min_days enforcement label version status"),
             c("country_code country_role nationality doc_required security_approval passport_min_days enforcement label version"),
             {P: "border.manage", O: None}, readonly_portals=(O,), creator_col="created_by", group="documents",
             actions=(Action("approve", {"status": "ACTIVE"}, {"status": ["DRAFT"]}, four_eyes=("created_by", "approved_by")),
                      retire())),
    Resource("ticket-document", M_INT, "sales.ticket_doc",
             c("ticket_id dest_country passport_expiry visa_type visa_country visa_valid residence_country residence_expiry "
               "security_authority security_expiry transit_permit_no status source verified_at"), (),
             {P: "border.manage", O: None}, create=False, update=False, order="ticket_id DESC", group="documents",
             actions=(Action("verify", {"status": "VERIFIED"}, {"status": ["PENDING", "REJECTED"]}, stamp="verified_at", by="verified_by"),
                      Action("reject", {"status": "REJECTED"}, {"status": ["PENDING", "VERIFIED"]}, stamp="verified_at", by="verified_by"))),

    # ------------------------------------------------------------- border points and profiles (11.6)
    Resource("border-point", M_BRD, "brd.border_point", c("station_id point_type country_code counterpart_station_id authority_id status"),
             c("station_id point_type country_code counterpart_station_id authority_id hours"), {P: "border.manage", O: None},
             readonly_portals=(O,), order="station_id", group="points",
             actions=(Action("close", {"status": "CLOSED"}, {"status": ["ACTIVE", "RESTRICTED"]}),
                      Action("restrict", {"status": "RESTRICTED"}, {"status": ["ACTIVE"]}),
                      Action("open", {"status": "ACTIVE"}, {"status": ["CLOSED", "RESTRICTED"]}))),
    Resource("crossing-profile", M_BRD, "brd.crossing_profile",
             c("border_point_id authority_id schema_version lead_time_min formats fail_policy valid status"),
             c("border_point_id authority_id required_fields lead_time_min schema_version formats fail_policy valid"),
             {P: "border.manage", O: None}, readonly_portals=(O,), group="points",
             actions=(Action("activate", {"status": "ACTIVE"}, {"status": ["DRAFT"]}), retire())),
    Resource("authority-alert", M_BRD, "sec.authority_alert",
             c("vehicle_id trip_id authority_id alert_type sent_to_authority sent_at response_ref created_at"),
             c("vehicle_id trip_id authority_id alert_type response_ref"), {P: "border.manage"}, group="points",
             actions=(Action("mark-sent", {"sent_to_authority": True}, {"sent_to_authority": [False]}, stamp="sent_at"),)),

    # ------------------------------------------------------------- manifests
    Resource("manifest", M_BRD, "brd.manifest",
             c("uid trip_id border_point_id version manifest_type content_type status closed_at created_at"), (),
             {P: "border.manage", O: "border.operate"}, create=False, update=False, filters=c("status"), group="manifests"),
    Resource("manifest-person", M_BRD, "brd.manifest_person",
             c("manifest_id person_role ticket_id crew_party_id doc_type issuing_country doc_expiry nationality birth_date sex "
               "passenger_category syria_entry_point_id syria_exit_point_id"), (),
             {P: "border.manage", O: "border.operate"}, create=False, update=False, order="manifest_id DESC, id", group="manifests"),
    Resource("manifest-vehicle", M_BRD, "brd.manifest_vehicle", c("manifest_id vehicle_id trailer_id plate_no plate_country chassis_no"), (),
             {P: "border.manage", O: "border.operate"}, create=False, update=False, order="manifest_id DESC", group="manifests"),
    Resource("manifest-cargo", M_BRD, "brd.manifest_cargo",
             c("manifest_id shipment_id leg_id cargo_category cargo_description hs_code declared_weight_kg packages container_no seal_no un_number adr_class"),
             c("manifest_id shipment_id leg_id cargo_category cargo_description hs_code declared_weight_kg packages container_no "
               "seal_no un_number adr_class temp_min_c temp_max_c"), {P: "border.manage", O: "border.operate"}, delete=True,
             group="manifests"),
    Resource("manifest-response", M_BRD, "brd.manifest_response",
             c("manifest_id subject_type subject_id decision reason_code silent_flag received_at"),
             c("manifest_id subject_type subject_id decision reason_code silent_flag"), {P: "border.manage", O: "border.operate"},
             readonly_portals=(O,), update=False, order="received_at DESC", group="manifests"),
    Resource("manifest-discrepancy", M_BRD, "brd.manifest_discrepancy",
             c("manifest_id discrepancy_type subject_type subject_id resolved_at created_at"),
             c("manifest_id discrepancy_type subject_type subject_id detail"), {P: "border.manage", O: "border.operate"},
             group="manifests", actions=(Action("resolve", {}, {}, stamp="resolved_at", by="resolved_by"),)),
]
