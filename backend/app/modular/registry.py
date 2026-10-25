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
    domain: str = "modules"   # the menu group the module's pages join when it is switched on (navg.* in the web)


MODULES = (
    Module("approved_lines", "2", "route", ("PLATFORM", "OPERATOR"), "network"),
    Module("shuttle_rides", "2", "directions_bus", ("PLATFORM", "OPERATOR", "PASSENGER", "DRIVER"), "services"),
    Module("shuttle_subscriptions", "2", "card_membership", ("PLATFORM", "OPERATOR", "PASSENGER"), "services"),
    Module("cargo", "3", "package_2", ("PLATFORM", "OPERATOR", "PASSENGER"), "shipping"),
    Module("trip_parcels", "3", "inventory_2", ("PLATFORM", "OPERATOR", "PASSENGER"), "shipping"),
    Module("international", "4", "public", ("PLATFORM", "OPERATOR"), "services"),
    Module("border_manifest", "4-6", "assignment_ind", ("PLATFORM", "OPERATOR"), "operations"),
    Module("gov_adapters", "5", "account_balance", ("PLATFORM",), "government"),
    Module("tracking_stations", "7", "monitor", ("PLATFORM", "OPERATOR"), "operations"),
    Module("freight", "8", "local_shipping", ("PLATFORM", "OPERATOR", "PASSENGER"), "shipping"),
    Module("intermediary_platforms", "9", "hub", ("PLATFORM", "AGENCY"), "partners"),
    Module("rail", "10", "train", ("PLATFORM", "OPERATOR"), "services"),
    Module("taxi", "11", "local_taxi", ("PLATFORM", "OPERATOR", "PASSENGER"), "services"),
    Module("car_rental", "12", "car_rental", ("PLATFORM", "OPERATOR", "PASSENGER"), "services"),
    Module("transit_passengers", "13", "move_up", ("PLATFORM", "OPERATOR"), "services"),
    Module("contract_transport", "14", "school", ("PLATFORM", "OPERATOR"), "services"),
    Module("carrier_billing", "core", "receipt_long", ("PLATFORM", "OPERATOR", "AGENCY"), "finance"),
    Module("service_partners", "core", "local_gas_station", ("PLATFORM", "OPERATOR", "PASSENGER"), "loyalty"),
    Module("loyalty_partners", "core", "loyalty", ("PLATFORM", "PASSENGER"), "loyalty"),
    Module("campaigns", "core", "campaign", ("PLATFORM",), "loyalty"),
    Module("accounting_ops", "core", "account_balance_wallet", ("PLATFORM", "OPERATOR", "AGENCY"), "finance"),
    Module("contact_center", "core", "support_agent", ("PLATFORM",), "support"),
    Module("passenger_categories", "core", "family_restroom", ("PLATFORM", "OPERATOR"), "sales"),
    Module("family_accounts", "core", "diversity_3", ("PLATFORM",), "sales"),          # passengers use the Family page
    Module("trip_manifests", "core", "fact_check", ("PLATFORM", "OPERATOR"), "operations"),
    # launch completeness (1054): screens for the launch-phase tables that had none
    Module("support_cases", "core", "support_agent", ("PLATFORM", "OPERATOR"), "support"),           # passengers use the Support page
    Module("pricing_setup", "core", "sell", ("PLATFORM", "OPERATOR"), "finance"),
    Module("loyalty", "core", "loyalty", ("PLATFORM", "PASSENGER"), "loyalty"),
    Module("fleet_records", "core", "directions_car", ("PLATFORM", "OPERATOR"), "fleet"),
    Module("security_console", "core", "verified_user", ("PLATFORM", "OPERATOR"), "security"),
    Module("finance_controls", "core", "account_balance", ("PLATFORM", "OPERATOR", "AGENCY"), "finance"),
    Module("data_governance", "core", "privacy_tip", ("PLATFORM",), "compliance"),
    Module("reference_data", "core", "data_table", ("PLATFORM",), "settings"),
    Module("school_transport", "SCH", "school", ("PLATFORM", "OPERATOR", "PASSENGER", "DRIVER"), "services"),
)
BY_KEY = {m.key: m for m in MODULES}
