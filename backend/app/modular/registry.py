"""The platform's modules and their switches.

Every module maps to one key of the sys.setting "features" document. A switched-off module answers 404
MODULE_DISABLED on every endpoint and disappears from the portals' menus; its tables stay intact.
"""
from dataclasses import dataclass


@dataclass(frozen=True)
class Module:
    key: str            # feature flag in sys.setting "features"
    phase: str          # study phase (21)
    icon: str           # Material Symbols name used by the web portals
    portals: tuple      # portals that show the module


MODULES = (
    Module("approved_lines", "2", "route", ("PLATFORM", "OPERATOR")),
    Module("shuttle_rides", "2", "directions_bus", ("PLATFORM", "OPERATOR", "PASSENGER", "DRIVER")),
    Module("shuttle_subscriptions", "2", "card_membership", ("PLATFORM", "OPERATOR", "PASSENGER")),
    Module("cargo", "3", "package_2", ("PLATFORM", "OPERATOR", "PASSENGER")),
    Module("international", "4", "public", ("PLATFORM", "OPERATOR")),
    Module("border_manifest", "4-6", "assignment_ind", ("PLATFORM", "OPERATOR")),
    Module("gov_adapters", "5", "account_balance", ("PLATFORM",)),
    Module("tracking_stations", "7", "monitor", ("PLATFORM", "OPERATOR")),
    Module("freight", "8", "local_shipping", ("PLATFORM", "OPERATOR", "PASSENGER")),
    Module("intermediary_platforms", "9", "hub", ("PLATFORM", "AGENCY")),
    Module("rail", "10", "train", ("PLATFORM", "OPERATOR")),
    Module("taxi", "11", "local_taxi", ("PLATFORM", "OPERATOR", "PASSENGER")),
    Module("car_rental", "12", "car_rental", ("PLATFORM", "OPERATOR", "PASSENGER")),
    Module("transit_passengers", "13", "move_up", ("PLATFORM", "OPERATOR")),
    Module("contract_transport", "14", "school", ("PLATFORM", "OPERATOR")),
    Module("carrier_billing", "core", "receipt_long", ("PLATFORM", "OPERATOR", "AGENCY")),
    Module("service_partners", "core", "local_gas_station", ("PLATFORM", "OPERATOR", "PASSENGER")),
    Module("loyalty_partners", "core", "loyalty", ("PLATFORM", "PASSENGER")),
    Module("campaigns", "core", "campaign", ("PLATFORM",)),
    Module("accounting_ops", "core", "account_balance_wallet", ("PLATFORM", "OPERATOR", "AGENCY")),
    Module("contact_center", "core", "support_agent", ("PLATFORM",)),
    Module("passenger_categories", "core", "family_restroom", ("PLATFORM", "OPERATOR")),
    Module("family_accounts", "core", "diversity_3", ("PLATFORM",)),          # passengers use the Family page
    Module("trip_manifests", "core", "fact_check", ("PLATFORM", "OPERATOR")),
    # launch completeness (1054): screens for the launch-phase tables that had none
    Module("support_cases", "core", "support_agent", ("PLATFORM", "OPERATOR")),           # passengers use the Support page
    Module("pricing_setup", "core", "sell", ("PLATFORM", "OPERATOR")),
    Module("loyalty", "core", "loyalty", ("PLATFORM", "PASSENGER")),
    Module("fleet_records", "core", "directions_car", ("PLATFORM", "OPERATOR")),
    Module("security_console", "core", "verified_user", ("PLATFORM", "OPERATOR")),
    Module("finance_controls", "core", "account_balance", ("PLATFORM", "OPERATOR", "AGENCY")),
    Module("data_governance", "core", "privacy_tip", ("PLATFORM",)),
    Module("reference_data", "core", "data_table", ("PLATFORM",)),
    Module("school_transport", "SCH", "school", ("PLATFORM", "OPERATOR", "PASSENGER", "DRIVER")),
)
BY_KEY = {m.key: m for m in MODULES}
