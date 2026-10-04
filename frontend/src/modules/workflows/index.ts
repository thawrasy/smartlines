import type { ComponentType } from "react";
import { FreightMarket } from "./carrier";
import { BuyPass, PostLoad, RentCar, RequestTaxi, SendParcel } from "./passenger";

/** Workflow screens per module and portal, shown after the dashboard and before the module's records. */
export const WORKFLOWS: Record<string, Record<string, { key: string; component: ComponentType }[]>> = {
  shuttle_subscriptions: { PASSENGER: [{ key: "buyPass", component: BuyPass }] },
  cargo: { PASSENGER: [{ key: "sendParcel", component: SendParcel }] },
  taxi: { PASSENGER: [{ key: "taxi", component: RequestTaxi }] },
  car_rental: { PASSENGER: [{ key: "rent", component: RentCar }] },
  freight: { PASSENGER: [{ key: "load", component: PostLoad }], OPERATOR: [{ key: "market", component: FreightMarket }, { key: "load", component: PostLoad }] },
};

/** Modules whose passenger page opens on a workflow rather than on the dashboard. */
export const WORKFLOW_FIRST = new Set(["shuttle_subscriptions", "cargo", "taxi", "car_rental", "freight"]);
